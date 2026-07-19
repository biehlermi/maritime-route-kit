# Data Provenance

Information on data sources, licensing, and rebuilding the routing grid.

## Overview

MaritimeRouteKit relies on open-source geographic data to build its offline routing network. Understanding the sources and licenses is crucial for compliance when distributing your app.

## Data Sources

The land/water mask and coastline definitions are primarily sourced from **Natural Earth** (public domain). Additional precise routing definitions for complex waterways are sourced from **OpenStreetMap (OSM)** contributors.

## Licensing

Because the routing grid incorporates OpenStreetMap data, the resulting dataset is subject to the **Open Data Commons Open Database License (ODbL)**.

> Important: If you publicly distribute an application using this framework, you must provide appropriate attribution to OpenStreetMap contributors as required by the ODbL.

## Rebuilding the Grid

The framework includes tools for regenerating the offline grid data if you need to update the source material or adjust the grid resolution. 

To rebuild the data, run the included python script located in the `Scripts/` directory of the repository:

```bash
python3 Scripts/build_routing_grid.py --resolution high
```
