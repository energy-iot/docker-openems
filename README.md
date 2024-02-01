# TO DO Describe briefly what each directory is and what is the source for each.  How is it updated, how to find out more?
This repository is used to host docker configuration files for openems backend


# .github folder

The .github/workflows folder is used to store GitHub Actions workflows that deploys openems on AWS ECS and it also contains the task definition file for ECS to update and restart itself after the workflow completely executes;

Things to consider include:

1. Availabity zones
For this project we used US-EAST-1A for the deployment, feel free to change it your desired availabity zones.

2. AWS Account Id
For this worflow to run change the aws id to the account you are using to deploy openems both in the deploy-pipeline yaml file and openems-demo-td json file.

${{ secrets.AWS_ACCESS_KEY_ID }}, ${{ secrets.AWS_SECRET_ACCESS_KEY }} values should be stored in github secrets.

******.dkr.ecr.us-east-1.amazonaws.com/openems-ui:latest: the ***** is the value for the aws account id that will run this deployment.


# IAC folder

This folder contains the infrastructure that will be built on aws using terraform as IAC tool.

Infrastructure includes:

1. VPC with 2 public subnets
2. Security groups
3. ECS task role
4. ECS Fargate


Things to consider include:

********Backend.tf File

- The bucket and the dynamodb should be created before-hand with any preferred naming.

bucket         = "***********openems-github-action-state-file***********"
key            = "openems-app/terraform.tfstate"
region         = "************us-east-1************"
dynamodb_table = "*************terraform-state-lock-openems*************"


*********Secret Manager
This iac uses secret manager to pass in credentials used in the ecs.tf file.


