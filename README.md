# Secure AI Delivery Platform

A production-style brownfield DevOps project for building, securing, deploying, observing and operating a model-serving application.

## Project goals

- Build and test the application with Jenkins.
- Protect pipeline credentials with Jenkins Credentials.
- Encrypt the model artifact and decrypt it securely at runtime.
- Build one immutable container image and promote it across environments.
- Maintain separate dev, test and production configuration and state.
- Deploy through both VM-based and Kubernetes-based workflows.
- Provision infrastructure with Terraform.
- Scan images and dependencies before promotion.
- Implement health checks, monitoring, alerting and rollback.
- Practise incidents, runbooks, recovery and root-cause analysis.

## Planned delivery flow

```text
Git
  -> Jenkins
  -> Test and security gates
  -> Immutable artifact
  -> Dev
  -> Test
  -> Manual approval
  -> Production
  -> Health validation or rollback