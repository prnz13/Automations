#!/bin/bash

docker compose -p ai-service-cg-v50112 -f content-generation-docker-compose.yaml up -d
sleep 0.5
docker compose -p ai-service-ea-v50112  -f execution-assisstant-docker-compose.yaml up -d
sleep 0.5
docker compose -p ai-service-ing-v50112   -f ingestion-docker-compose.yaml up -d
sleep 0.5
docker compose -p ai-service-sga-v50112   -f sga-docker-compose.yaml up -d
sleep 0.5
docker compose -p ai-service-sg-v50112   -f smart-generation-docker-compose.yaml up -d
