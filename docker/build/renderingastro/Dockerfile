# escape=`

#
# Development-only image for running Next.js in a containerized environment.
# Assumes that the Next.js rendering host source is mounted to c:\app.
#

ARG PARENT_IMAGE
FROM ${PARENT_IMAGE} as debug

WORKDIR /app

EXPOSE 3000
#ENTRYPOINT "npm install && npm install next@canary && npm run start:connected"
ENTRYPOINT "npm install && npm run preview"