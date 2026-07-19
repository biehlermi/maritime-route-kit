[out:json][timeout:240];
(
  way["waterway"="canal"](8.70,-80.10,9.50,-79.35);
  way["natural"="water"]["water"~"^(canal|lake)$"](8.70,-80.10,9.50,-79.35);
  relation["natural"="water"]["water"~"^(canal|lake)$"](8.70,-80.10,9.50,-79.35);
);
out geom;
