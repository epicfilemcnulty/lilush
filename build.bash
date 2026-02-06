#!/bin/bash

ln -s dockerfiles/lilush Dockerfile
docker build -t lilush .
docker cp $(docker create --name lilush lilush):/usr/bin/lilush .
docker rm lilush
