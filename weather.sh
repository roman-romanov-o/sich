#!/usr/bin/env bash
# Check the weather. Usage: ./weather.sh [city]   (defaults to your location)
curl -fsS "wttr.in/${1:-}?format=3" || { echo "weather unavailable"; exit 1; }
