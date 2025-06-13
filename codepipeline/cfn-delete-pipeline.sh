#!/bin/bash

# This script deploys a CloudFormation stack

STACK_NAME="codepipeline-pipeline-cfn"

echo "Deleting CloudFormation stack: $STACK_NAME"
aws cloudformation delete-stack \
  --stack-name $STACK_NAME

if [ $? -eq 0 ]; then
  echo "CloudFormation stack $STACK_NAME deleted successfully."
else
  echo "Failed to delete CloudFormation stack $STACK_NAME."
  exit 1
fi

# Wait for the stack to be deleted
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"

if [ $? -eq 0 ]; then
  echo "Stack $STACK_NAME deletion completed successfully."
else
  echo "Failed to delete stack $STACK_NAME."
  exit 1
fi
