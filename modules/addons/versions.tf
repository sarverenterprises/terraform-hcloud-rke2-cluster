terraform {
  required_version = ">= 1.11"

  required_providers {
    # Helm and Kubernetes providers are passed through from the root module.
    # The root module's caller (examples/) configures them with the cluster
    # kubeconfig after the first terraform apply phase completes.
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.14.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.31.0"
    }
    # tls is used by flux.tf to generate the SSH deploy keypair.
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
    # null is used by flux.tf for the GitHub deploy-key auto-registration
    # local-exec provisioner.
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
    # random is used by monitoring.tf for Grafana admin password generation.
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}
