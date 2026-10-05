-- =============================================================================
-- NYC Hydrant Density Analysis. analysis.sql
-- Portfolio Project 2, Modern GIS Accelerator
--
-- Five progressive PostGIS queries that build up to a normalized density
-- analysis and a 100-meter coverage analysis.
--
-- Assumes:
--   - Database "gis" (PostGIS in Docker on port 5435; see README)
--   - Tables created by load_data.sh (ogr2ogr)
--   - Spatial (GiST) indexes on both geom columns, created by ogr2ogr during the load
--
-- Run all queries:
--   psql -h localhost -p 5435 -U gis -d gis -f analysis.sql
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Query 1: Filter
--
-- Goal: Sanity check that the data loaded. Pull all neighborhoods in Manhattan.
-- Expected output: ~37 rows (Manhattan neighborhoods).
-- -----------------------------------------------------------------------------

SELECT ntaname, boroname
FROM nyc_neighborhoods
WHERE boroname = 'Manhattan'
ORDER BY ntaname;


-- -----------------------------------------------------------------------------
-- Query 2: Spatial join
--
-- Goal: Match each hydrant to the neighborhood that contains it, using
-- ST_Contains.
-- Expected output: one row per hydrant (~109,725) with the neighborhood name.
-- -----------------------------------------------------------------------------

SELECT h.unitid AS "Hydrant ID", n.ntaname AS "Neighborhood", n.boroname AS "Boro" 
FROM nyc_hydrants h 
LEFT JOIN nyc_neighborhoods n
    ON ST_Contains(n.geom, h.geom)
LIMIT 10;

-- -----------------------------------------------------------------------------
-- Query 3: Aggregate
--
-- Goal: Count hydrants per neighborhood.
-- Expected output: 197 rows (one per residential neighborhood ntatype = '0') with a hydrant_count.
-- -----------------------------------------------------------------------------

SELECT n.ntaname, n.boroname, COUNT(h.unitid) AS hydrant_count
FROM nyc_neighborhoods n
LEFT JOIN nyc_hydrants h
     ON ST_Contains(n.geom, h.geom)
WHERE n.ntatype = '0'
GROUP BY n.ntaname, n.boroname
ORDER BY hydrant_count DESC;


-- -----------------------------------------------------------------------------
-- Query 4: Normalize (this is your headline result)
--
-- Goal: Compute density per square kilometer. Reproject to EPSG:2263
-- (NY State Plane Long Island, feet) before computing area, then convert
-- square feet to square kilometers.
-- Expected output: 262 rows with hydrant_count, area_km2, density_per_km2.
-- -----------------------------------------------------------------------------

SELECT n.ntaname, n.boroname,
ROUND( 
    (ST_Area(ST_Transform(n.geom, 2263)) / 10763910.42)::numeric, 2) AS area_km2,
COUNT(h.unitid) as hydrant_count,
ROUND(
    COUNT(h.unitid) / (ST_Area(ST_Transform(n.geom, 2263)) / 10763910.42)::numeric, 2) AS density_per_km2
FROM nyc_neighborhoods n
LEFT JOIN nyc_hydrants h
     ON ST_Contains(n.geom, h.geom)
WHERE n.ntatype = '0'
GROUP BY n.ntaname, n.boroname, n.geom
ORDER BY density_per_km2 DESC;

-- Alternate version of Query 4 using ::geography casting instead of
-- ST_Transform to EPSG:2263. Kept here as a learning exercise comparing
-- the two approaches; the version above is the one actually used.
/*
SELECT n.ntaname, n.boroname, 
ROUND(
    (ST_Area(n.geom::geography) / 1000000)::numeric, 2) AS area_km2,
COUNT(h.unitid) as hydrant_count,
ROUND(
    COUNT(h.unitid) / (ST_Area(n.geom::geography) / 1000000)::numeric, 2) AS density_per_km2
FROM nyc_neighborhoods n
LEFT JOIN nyc_hydrants h
     ON ST_Contains(n.geom, h.geom)
WHERE n.ntatype = '0'
GROUP BY n.ntaname, n.boroname, n.geom
ORDER BY density_per_km2 DESC;
*/

-- -----------------------------------------------------------------------------
-- Query 5: Buffer + Union + Intersection (coverage analysis)
--
-- Goal: For each neighborhood, what percent of its area is within 100 meters
-- of a hydrant? This is the deeper finding.
-- Expected output: 197 rows (residential neighborhoods) with ntaname, area_km2, covered_pct (as a percent)..
-- -----------------------------------------------------------------------------

WITH hydrant_coverage AS (
    -- 100 m buffers on geography (meters), cast back to geometry, unioned,
    -- then projected once to EPSG:2263
    SELECT ST_Transform(
               ST_Union(ST_Buffer(h.geom::geography, 100)::geometry),
               2263) AS coverage_geom
    FROM nyc_hydrants h
)
SELECT n.ntaname, n.boroname,
       ROUND((ST_Area(ST_Transform(n.geom, 2263)) / 10763910.42)::numeric, 2) AS area_km2,
       ROUND((100 * ST_Area(ST_Intersection(ST_Transform(n.geom, 2263), hc.coverage_geom))
                  / ST_Area(ST_Transform(n.geom, 2263)))::numeric, 2) AS covered_pct
FROM nyc_neighborhoods n
CROSS JOIN hydrant_coverage hc
WHERE n.ntatype = '0'
ORDER BY covered_pct DESC;


-- Query 5b: median coverage across residential neighborhoods
WITH hydrant_coverage AS (
    SELECT ST_Transform(
               ST_Union(ST_Buffer(h.geom::geography, 100)::geometry),
               2263) AS coverage_geom
    FROM nyc_hydrants h
),
cov AS (
    SELECT 100 * ST_Area(ST_Intersection(ST_Transform(n.geom, 2263), hc.coverage_geom))
               / ST_Area(ST_Transform(n.geom, 2263)) AS covered_pct
    FROM nyc_neighborhoods n
    CROSS JOIN hydrant_coverage hc
    WHERE n.ntatype = '0'
)
SELECT ROUND((percentile_cont(0.5) WITHIN GROUP (ORDER BY covered_pct))::numeric, 2) AS median_covered_pct
FROM cov;





-- =============================================================================
-- Notes for your README
--
-- - Query 1 is your sanity check. Don't skip it.
-- - Query 4 is your headline. Identify the top 5 and bottom 5 neighborhoods.
-- - Query 5 is the deeper insight. Look at the median covered_pct. That number
--   is your case-study finding.
-- =============================================================================
