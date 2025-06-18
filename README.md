# Automating AWS Infrastructure Provisioning with CodePipeline and CloudFormation Nested Stacks

In this blog post, we’re diving into a hands-on, automated approach to provisioning and managing AWS infrastructure using AWS CodePipeline with CloudFormation templates, including nested stacks. This setup is built to support a GitOps-style deployment, allowing infrastructure to be defined, versioned, and promoted through multiple environments—Development, Staging, and Production—straight from your Git repository.

Previously, we explored CloudFormation Git Sync for standalone stacks, showcasing how changes committed to a Git repository can automatically update AWS infrastructure. Today, we’re taking that concept further by incorporating CloudFormation nested stacks, which offer a scalable, modular approach to managing complex infrastructure codebases.

### Why CodePipeline?
AWS CodePipeline is a fully managed continuous integration and delivery (CI/CD) service that automates build, test, and deployment phases of your release process. With native integrations to services like CodeBuild, CloudFormation, CodeStar Connections, and GitHub, it's a great fit for managing infrastructure as code (IaC) workflows.

By connecting GitHub to CodePipeline using CodeStar Connections, and leveraging CodeBuild for validation steps like linting, we can automate a secure, repeatable, and robust infrastructure deployment process.


### Architecture Overview

- Three environments: Development, Staging, and Production
- One Git repository: Contains folders representing each environment
- CloudFormation Nested Stacks: Used for modularizing common resources (like VPCs, IAM roles, and S3 buckets)
- CodePipeline: Automates deployments by detecting changes in the GitHub repo and applying the appropriate CloudFormation templates
- CodeBuild: Lints CloudFormation templates to ensure they are syntactically and structurally correct

### Step 1: Create Prerequisite Components Using CloudFormation

- `GitHubConnection`: The CodeStar connection to GitHub
- `PipelineArtifactStoreS3Bucket`: Stores pipeline artifacts and CloudFormation templates
- `CfnlintCodeBuildProject`: Lints .yaml and .yml files in the infrastructure directory
- `CodeBuildServiceRole`: Grants permissions to CodeBuild to access logs, S3, and CodeStar
- `CloudFormationExecutionRole`: Used by CloudFormation to deploy stacks with permissions to access S3, IAM, and SSM
- `CodePipelineRole`: Allows CodePipeline to invoke actions using the above resources

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: 'CodeStar connection, CodePipeline for CFN stacks creation'

Parameters:
  BranchName:
    Type: String
    Default: 'main'
  FullRepositoryId:
    Type: String
    Default: 'chinmayto/cloudformation-gitops-with-codepipeline'
  CodePipelineName:
    Type: String
    Default: 'webserver-from-git'
  ConnectionName:
    Type: String
    Default: 'GitHub-to-CodePipeline'
  S3BucketName:
    Type: String
    Default: 'ct-cfn-files-for-stack'
  CodeBuildProjectName:
    Type: String
    Default: 'cfnlint-project'

Resources:
#####################################
# CodeStar Connection
#####################################
  GitHubConnection:
    Type: 'AWS::CodeStarConnections::Connection'
    Properties:
      ConnectionName: !Ref ConnectionName
      ProviderType: 'GitHub'

#####################################
# S3 bucket for CFN nested stack templates
#####################################
  PipelineArtifactStoreS3Bucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Ref S3BucketName

  PipelineArtifactStoreS3BucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref PipelineArtifactStoreS3Bucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowS3AccessForPipelineServices
            Principal:
              Service:
                - cloudformation.amazonaws.com
                - codebuild.amazonaws.com
                - codepipeline.amazonaws.com
            Effect: Allow
            Action: 
              - s3:GetObject
              - s3:GetObjectVersion
              - s3:PutObject
              - s3:ListBucket
            Resource: 
              - !Sub 'arn:${AWS::Partition}:s3:::${S3BucketName}/*'
              - !Sub 'arn:${AWS::Partition}:s3:::${S3BucketName}'

#####################################
# CodeBuild project
#####################################
  CodeBuildServiceRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: CodeBuildServiceRole
      AssumeRolePolicyDocument:
        Version: 2012-10-17
        Statement:
          - Effect: Allow
            Principal:
              Service: codebuild.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: CodeBuildBasePolicy
          PolicyDocument:
            Version: 2012-10-17
            Statement:
              - Effect: Allow
                Action:
                  - logs:CreateLogGroup
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                Resource: !Sub 'arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/codebuild/${CodeBuildProjectName}:*'
              - Effect: Allow
                Action:
                  - s3:GetObject
                  - s3:GetObjectVersion
                  - s3:PutObject
                Resource:
                  - !Sub 'arn:${AWS::Partition}:s3:::${S3BucketName}/*'
              - Effect: Allow
                Action:
                  - codeconnections:GetConnectionToken
                Resource: !GetAtt GitHubConnection.ConnectionArn

  CfnlintCodeBuildProject:
    Type: 'AWS::CodeBuild::Project'
    Properties:
      Name: !Ref CodeBuildProjectName
      Description: 'Project to run cfn-lint on the source code'
      Artifacts:
        Type: CODEPIPELINE
      Environment:
        Type: LINUX_CONTAINER
        ComputeType: BUILD_GENERAL1_SMALL
        Image: aws/codebuild/standard:5.0
        EnvironmentVariables: []
      Source:
        Type: CODEPIPELINE
        BuildSpec: |
          version: 0.2
          phases:
            install:
              commands:
                - echo "Installing CloudFormation Linter:"
                - pip install cfn-lint --user
            build:
              commands:
                - echo "Running linter on infrastructure directory:"
                - |
                  ERR=0
                  for file in $(find ./infrastructure -type f \( -iname "*.yaml" -o -iname "*.yml" \)); do
                    cfn-lint "$file" || ERR=1
                  done
                  if [ "$ERR" -eq "1" ]; then
                    exit 1
                  fi
          artifacts:
            files:
              - '**/*'
      ServiceRole: !Ref CodeBuildServiceRole

#####################################
# CodePipeline pipeline
#####################################
  CloudFormationExecutionRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: CloudFormationExecutionRole
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: 
                - cloudformation.amazonaws.com
            Action: 
              - sts:AssumeRole
      Policies:
        - PolicyName: !Sub "CloudFormationDeploymentPolicy"
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Action:
                  - ec2:*
                  - autoscaling:*
                  - iam:PassRole
                  - iam:GetRole
                  - iam:CreateInstanceProfile
                  - iam:AddRoleToInstanceProfile
                  - iam:RemoveRoleFromInstanceProfile
                  - iam:DeleteInstanceProfile
                  - iam:CreateRole
                  - iam:PutRolePolicy
                  - iam:AttachRolePolicy
                  - iam:ListInstanceProfiles
                  - iam:ListRoles
                  - iam:DeleteRolePolicy
                  - iam:TagRole
                  - iam:DeleteRole
                  - iam:GetInstanceProfile
                  - iam:getRolePolicy
                  - ssm:GetParameter
                  - ssm:GetParameters
                  - logs:*
                  - cloudwatch:PutMetricData
                  - cloudformation:*
                  - s3:ListBucket
                  - s3:GetObject
                  - s3:PutObject
                  - s3:DeleteObject
                Resource: "*"
        - PolicyName: CloudFormationPassRolePolicy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - iam:PassRole
                Resource: !Sub 'arn:aws:iam::197317184204:role/CloudFormationExecutionRole'

  CodePipelineRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: CodePipelineRole
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: codepipeline.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: CodeStarSourceConnectionAccessPolicy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: 'Allow'
                Action:
                  - codestar-connections:UseConnection
                Resource: !Sub 'arn:${AWS::Partition}:codestar-connections:${AWS::Region}:${AWS::AccountId}:connection/*'
        - PolicyName: CodeBuildPolicy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - codebuild:BatchGetBuilds
                  - codebuild:StartBuild
                Resource: !Sub 'arn:${AWS::Partition}:codebuild:${AWS::Region}:${AWS::AccountId}:project/${CfnlintCodeBuildProject}'
              - Effect: Allow
                Action:
                  - s3:GetObject
                  - s3:GetObjectVersion
                  - s3:PutObject
                Resource: !Sub 'arn:${AWS::Partition}:s3:::${S3BucketName}/*'
              - Effect: Allow
                Action:
                  - s3:ListBucket
                Resource: !Sub 'arn:${AWS::Partition}:s3:::${S3BucketName}'
              - Effect: Allow
                Action:
                  - s3:ListBucket
                Resource:
                  - !Sub 'arn:${AWS::Partition}:s3:::${S3BucketName}'
        - PolicyName: CodeDeployPolicy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - cloudformation:CreateStack
                  - cloudformation:DeleteStack
                  - cloudformation:DescribeStacks
                  - cloudformation:UpdateStack
                  - cloudformation:DescribeStackEvents
                  - cloudformation:SetStackPolicy
                  - cloudformation:ValidateTemplate
                Resource: '*'
        - PolicyName: CodePipelinePassRolePolicy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - iam:PassRole
                Resource: 
                  - !GetAtt CloudFormationExecutionRole.Arn
                  - !GetAtt CodeBuildServiceRole.Arn
                Condition:
                  StringEqualsIfExists:
                    iam:PassedToService:
                      - cloudformation.amazonaws.com
                      - codebuild.amazonaws.com

  CreateCfnStackFromRepo:
    Type: 'AWS::CodePipeline::Pipeline'
    Properties:
      Name: !Ref CodePipelineName
      RoleArn: !GetAtt CodePipelineRole.Arn
      ArtifactStore:
        Type: S3
        Location: !Ref S3BucketName
      Stages:
        - Name: Source
          Actions:
            - Name: Source
              ActionTypeId:
                Category: Source
                Owner: AWS
                Provider: CodeStarSourceConnection
                Version: '1'
              RunOrder: 1
              Configuration:
                BranchName: !Ref BranchName
                ConnectionArn: !GetAtt GitHubConnection.ConnectionArn
                DetectChanges: 'true'
                FullRepositoryId: !Ref FullRepositoryId
                OutputArtifactFormat: CODE_ZIP
              OutputArtifacts:
                - Name: SourceArtifact
              Namespace: SourceVariables
        - Name: CFN-Lint
          Actions:
            - Name: Run-CFN-Lint
              ActionTypeId:
                Category: Build
                Owner: AWS
                Provider: CodeBuild
                Version: '1'
              Configuration:
                ProjectName: !Ref CfnlintCodeBuildProject
              InputArtifacts:
                - Name: SourceArtifact
              OutputArtifacts:
                - Name: CflintArtifact
              RunOrder: 1
        - Name: Copy-to-S3
          Actions:
            - Name: Copy-to-S3
              ActionTypeId:
                Category: Deploy
                Owner: AWS
                Provider: S3
                Version: '1'
              RunOrder: 1
              Configuration:
                BucketName: !Ref S3BucketName
                Extract: 'true'
              InputArtifacts:
                - Name: SourceArtifact
        - Name: Deploy-CFN-stacks
          Actions:
            - Name: DeployDevelopmentStack
              ActionTypeId:
                Category: Deploy
                Owner: AWS
                Provider: CloudFormation
                Version: '1'
              Configuration:
                ActionMode: CREATE_UPDATE
                Capabilities: 'CAPABILITY_NAMED_IAM,CAPABILITY_AUTO_EXPAND'
                StackName: !Sub '${CodePipelineName}-development'
                TemplatePath: SourceArtifact::infrastructure/development/root.yaml
                RoleArn: !GetAtt CloudFormationExecutionRole.Arn
                ParameterOverrides: |
                  {
                    "Environment": "development"
                  }
              InputArtifacts:
                - Name: SourceArtifact
              RunOrder: 1
            - Name: DeployStagingStack
              ActionTypeId:
                Category: Deploy
                Owner: AWS
                Provider: CloudFormation
                Version: '1'
              Configuration:
                ActionMode: CREATE_UPDATE
                Capabilities: 'CAPABILITY_NAMED_IAM,CAPABILITY_AUTO_EXPAND'
                StackName: !Sub '${CodePipelineName}-staging'
                TemplatePath: SourceArtifact::infrastructure/staging/root.yaml
                RoleArn: !GetAtt CloudFormationExecutionRole.Arn
                ParameterOverrides: |
                  {
                    "Environment": "staging"
                  }
              InputArtifacts:
                - Name: SourceArtifact
              RunOrder: 1
            - Name: DeployProductionStack
              ActionTypeId:
                Category: Deploy
                Owner: AWS
                Provider: CloudFormation
                Version: '1'
              Configuration:
                ActionMode: CREATE_UPDATE
                Capabilities: 'CAPABILITY_NAMED_IAM,CAPABILITY_AUTO_EXPAND'
                StackName: !Sub '${CodePipelineName}-production'
                TemplatePath: SourceArtifact::infrastructure/production/root.yaml
                RoleArn: !GetAtt CloudFormationExecutionRole.Arn
                ParameterOverrides: |
                  {
                    "Environment": "production"
                  }
              InputArtifacts:
                - Name: SourceArtifact
              RunOrder: 1

```

You can apply this template using a simple shell script like below:

```shell
#!/bin/bash

# This script deploys a CloudFormation stack

STACK_NAME="codepipeline-pipeline-cfn"

echo "Deploying CloudFormation stack: $STACK_NAME"
aws cloudformation deploy \
  --stack-name $STACK_NAME \
  --template-file codepipeline_pipeline.yaml \
  --capabilities CAPABILITY_NAMED_IAM --disable-rollback

if [ $? -eq 0 ]; then
  echo "CloudFormation stack $STACK_NAME deployed successfully."
else
  echo "Failed to deploy CloudFormation stack $STACK_NAME."
  exit 1
fi

# Wait for the stack to be created
aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME"

if [ $? -eq 0 ]; then
  echo "Stack $STACK_NAME creation completed successfully."
else
  echo "Failed to create stack $STACK_NAME."
  exit 1
fi
```

Run the shell script:
```shell
$ ./cfn-deploy-pipeline.sh 
Deploying CloudFormation stack: codepipeline-pipeline-cfn

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - codepipeline-pipeline-cfn
CloudFormation stack codepipeline-pipeline-cfn deployed successfully.
Stack codepipeline-pipeline-cfn creation completed successfully.
```

### Step 2: Authorize GitHub in CodeStar Connection

Once the connection is created, go back to the Connections tab in the AWS console and authorize GitHub access.

At times, if you had previously linked your repository to your AWS account using a CodeStar connection, deleting and recreating the connection might still cause issues when creating a new CloudFormation stack—AWS may continue referencing the "old" connection. To resolve this, you should unlink the repository using the AWS CLI and then link it again to refresh the connection. Make sure to authorize again via the console after creating a new connection.

List connection
```shell
aws codestar-connections list-repository-links
```

Delete repository link
```shell
aws codestar-connections delete-repository-link --repository-link-id ac01d54c-dcc7-4b4e-97bf-f70592f1377d
```

### Step 3: Watch Initial Pipeline Run
Once the stack is deployed and the pipeline is created, CodePipeline automatically starts an initial run:

1. It detects changes from the specified GitHub branch
2. Downloads the templates
3. Runs cfn-lint via CodeBuild
4. Deploys nested stacks using CloudFormation

### Step 4: Make Changes and Watch Them Deploy

With the GitOps model in place, any change committed to the GitHub repo will trigger the pipeline. For example:

Lets update the desired capacity of autoscaling group to 2 for development environment


### Cleanup
When you are done testing or no longer need the stacks, delete them manually via the AWS Console or CLI

```shell
aws cloudformation delete-stack --stack-name codepipeline-pipeline-cfn
aws cloudformation delete-stack --stack-name webserver-from-git-development
aws cloudformation delete-stack --stack-name webserver-from-git-staging
aws cloudformation delete-stack --stack-name webserver-from-git-production
```

### Conclusion
By combining CloudFormation nested stacks with CodePipeline and GitHub, we've created a robust automation pipeline that supports infrastructure deployments across multiple environments. This solution builds upon the GitOps paradigm, enabling a safer, more auditable way to manage AWS infrastructure at scale.

This approach not only improves deployment consistency but also integrates seamlessly with developer workflows—making infrastructure provisioning as easy as a git push.

References
GitHub Repo: https://github.com/chinmayto/cloudformation-gitops-with-codepipeline
How to model GitOps environments: https://codefresh.io/blog/how-to-model-your-gitops-environments-and-promote-releases-between-them/
