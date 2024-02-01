# Set AWS details
ECR_URI="${ACCESS_KEY_ID}.dkr.ecr.${REGION}.amazonaws.com"


# Assuming docker-compose.yml is in the same directory as the script
COMPOSE_FILE="docker-compose.yml"

# Extract image names from the Docker Compose file
# This command depends on the structure of your Docker Compose file
# For example, if your image names are under 'image:' keys
IMAGES=$(grep 'image:' $COMPOSE_FILE | awk '{print $2}')

# Tag and push each image
for IMAGE in $IMAGES; do
    # Tag the image
    docker tag $IMAGE $ECR_URI/$IMAGE

    # Push the image
    docker push $ECR_URI/$IMAGE
done

echo "All images pushed to ECR."