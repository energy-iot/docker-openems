# Backend Docker (with TimeDB Influx)

Container provides an OpenEMS Backend with a pre configured influxdb connected.

## Running
`docker run --name openems-backend --net='host' -d stromdao/openems-backend`

## Usage
Apache Felix Web Console configuration: http://localhost:8079/system/console/configMgr

## Build Image

docker buildx build -t openems-backend:1.0 .

## Push Image to Amazon ECR

-- Create IAM User
-- Configure Pragrammatic Access
-- Create the amazon repository
-- login to ECR

-- Push docker image -- docker push (repo URI)



