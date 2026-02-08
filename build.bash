#!/bin/bash
APP=${1:-lilush}
docker build --build-arg APP=${APP} -t lilush-build .
docker cp $(docker create --name lilush-build lilush-build):/build/${APP} ./${APP}
docker rm lilush-build
