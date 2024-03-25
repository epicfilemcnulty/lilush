#!/bin/bash

repo=${GITHUB_REPOSITORY}
docker tag git.deviant.guru/${repo}:latest git.deviant.guru/${repo}:${GITHUB_REF_NAME} 
docker login -u ci -p "${CI_REGISTRY_PASSWORD}" git.deviant.guru
docker push git.deviant.guru/${repo}:${GITHUB_REF_NAME}
docker logout

id=$(docker create git.deviant.guru/${repo}:${GITHUB_REF_NAME})
docker cp ${id}:/bin/lilush ${CI_ASSETS_DIR}/lilush
docker rm ${id}
