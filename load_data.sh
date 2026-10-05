#!/usr/bin/env bash
# load_data.sh
# ---------------------------------------------------------------------------
# Downloads NYC Open Data GeoJSON files and loads them into PostGIS using
# ogr2ogr (part of GDAL).
#
# Inputs:   None — downloads data from NYC Open Data API.
# Outputs:  Two PostGIS tables in the "gis" database:
#           - nyc_neighborhoods  (~262 rows, MultiPolygon, EPSG:4326)
#           - nyc_hydrants       (~109,000 rows, Point, EPSG:4326)
#
# Prerequisites:
#   - Docker container "gis_postgis" running
#   - GDAL installed (ogr2ogr --version to check)
#
# Connection settings default to this project's local dev setup and can be
# overridden with environment variables, e.g.:
#   PGPASSWORD=mysecret bash load_data.sh
#
# Usage:    bash load_data.sh
# ---------------------------------------------------------------------------

set -e  # Stop on first error so you see exactly which step failed

# --- Configuration ----------------------------------------------------------
DATA_DIR="./data/raw"
CONTAINER="gis_postgis"

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5435}"
PGDATABASE="${PGDATABASE:-gis}"
PGUSER="${PGUSER:-gis}"
PGPASSWORD="${PGPASSWORD:-gis}"

PG="PG:host=$PGHOST port=$PGPORT dbname=$PGDATABASE user=$PGUSER password=$PGPASSWORD"

# NYC Open Data SODA API endpoints (GeoJSON format)
NTA_URL="https://data.cityofnewyork.us/resource/9nt8-h7nd.geojson?\$limit=300"
HYDRANT_URL="https://data.cityofnewyork.us/resource/5bgh-vtsn.geojson?\$limit=120000"

# --- Create data directory ---------------------------------------------------
mkdir -p "$DATA_DIR"
echo "Data directory ready: $DATA_DIR"

# --- Download neighborhoods -----------------------------------------------
echo ""
echo "Downloading NYC Neighborhood Tabulation Areas (NTAs)..."
curl -L -o "$DATA_DIR/nyc_neighborhoods.geojson" "$NTA_URL"

FILE_SIZE=$(wc -c < "$DATA_DIR/nyc_neighborhoods.geojson" | tr -d ' ')
if [ "$FILE_SIZE" -lt 1000 ]; then
    echo "ERROR: neighborhoods file is only $FILE_SIZE bytes — download may have failed."
    exit 1
fi
echo "Downloaded nyc_neighborhoods.geojson ($FILE_SIZE bytes)"

# --- Download hydrants ----------------------------------------------------
echo ""
echo "Downloading NYC fire hydrants (this may take a minute — ~110K records)..."
curl -L -o "$DATA_DIR/nyc_hydrants.geojson" "$HYDRANT_URL"

FILE_SIZE=$(wc -c < "$DATA_DIR/nyc_hydrants.geojson" | tr -d ' ')
if [ "$FILE_SIZE" -lt 1000 ]; then
    echo "ERROR: hydrants file is only $FILE_SIZE bytes — download may have failed."
    exit 1
fi
echo "Downloaded nyc_hydrants.geojson ($FILE_SIZE bytes)"

# --- Wait for PostGIS to be ready -----------------------------------------
echo ""
echo "Checking PostGIS connection..."
for i in $(seq 1 10); do
    if docker exec -e PGPASSWORD="$PGPASSWORD" "$CONTAINER" pg_isready -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" > /dev/null 2>&1; then
        echo "PostGIS is ready"
        break
    fi
    if [ "$i" -eq 10 ]; then
        echo "ERROR: Could not connect to PostGIS after 10 attempts."
        echo "   Make sure the container is running (check Docker Desktop)."
        exit 1
    fi
    echo "   Waiting for PostGIS... (attempt $i/10)"
    sleep 3
done

# --- Load neighborhoods into PostGIS --------------------------------------
echo ""
echo "Loading neighborhoods into PostGIS..."
ogr2ogr \
    -f "PostgreSQL" \
    "$PG" \
    "$DATA_DIR/nyc_neighborhoods.geojson" \
    -nln nyc_neighborhoods \
    -overwrite \
    -lco GEOMETRY_NAME=geom \
    -lco FID=gid \
    -t_srs EPSG:4326

echo "Loaded nyc_neighborhoods table"

# --- Load hydrants into PostGIS -------------------------------------------
echo ""
echo "Loading hydrants into PostGIS (this may take a moment)..."
ogr2ogr \
    -f "PostgreSQL" \
    "$PG" \
    "$DATA_DIR/nyc_hydrants.geojson" \
    -nln nyc_hydrants \
    -overwrite \
    -lco GEOMETRY_NAME=geom \
    -lco FID=gid \
    -t_srs EPSG:4326

echo "Loaded nyc_hydrants table"

# --- Verify ---------------------------------------------------------------
echo ""
echo "Verifying loaded data..."
echo ""

echo "--- Neighborhood count ---"
docker exec -e PGPASSWORD="$PGPASSWORD" "$CONTAINER" psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -c \
    "SELECT COUNT(*) AS neighborhood_count FROM nyc_neighborhoods;"

echo ""
echo "--- Hydrant count ---"
docker exec -e PGPASSWORD="$PGPASSWORD" "$CONTAINER" psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -c \
    "SELECT COUNT(*) AS hydrant_count FROM nyc_hydrants;"

echo ""
echo "--- Geometry columns ---"
docker exec -e PGPASSWORD="$PGPASSWORD" "$CONTAINER" psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -c \
    "SELECT f_table_name, type, srid FROM geometry_columns ORDER BY f_table_name;"

echo ""
echo "All done. Your PostGIS database is loaded and ready."
echo "   Connect with: psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE"