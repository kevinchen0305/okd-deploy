# modules/vpc

Terraform module that provisions a dedicated VPC for a single OKD 4.18 cluster
on AWS.

## What it creates

- 1 VPC (DNS hostnames + DNS support enabled)
- 1 Internet Gateway
- 1 public subnet in the chosen AZ (auto-assign public IPv4 enabled)
- 1 private subnet in the same AZ
- 1 EIP + 1 NAT Gateway (in the public subnet)
- public route table (0.0.0.0/0 -> IGW) associated to the public subnet
- private route table (0.0.0.0/0 -> NAT GW) associated to the private subnet
- 1 S3 Gateway VPC endpoint, attached to both route tables
- `var.worker_replicas` EIPs pre-allocated for worker nodes, tagged
  `okd-deploy/role=worker-eip`. The installer brings workers up first; the
  `scripts/attach-worker-eips.sh` step in `okd-build` then associates each EIP
  to a worker EC2 instance. EIPs survive `openshift-install destroy` and are
  released by `terraform destroy`.

All resources are tagged with `Name = "<cluster_name>-..."` and the
OKD-installer-required `kubernetes.io/cluster/<cluster_name> = shared`. Any
extra tags provided via `var.tags` are merged in.

## Usage as a child module

From `clusters/<name>/terraform/main.tf`:

```hcl
module "vpc" {
  source = "../../modules/vpc"

  cluster_name = "my-okd"
  region       = "ap-northeast-1"
  az           = "ap-northeast-1a"

  # Optional overrides:
  # cidr                = "10.0.0.0/16"
  # public_subnet_cidr  = "10.0.0.0/24"
  # private_subnet_cidr = "10.0.16.0/20"
  # tags = {
  #   Owner = "platform"
  # }
}

output "vpc_id"            { value = module.vpc.vpc_id }
output "public_subnet_id"  { value = module.vpc.public_subnet_id }
output "private_subnet_id" { value = module.vpc.private_subnet_id }
```

The caller is responsible for declaring the `aws` provider and configuring its
region / credentials.

## Inputs

| Name                  | Type           | Default          | Description                        |
| --------------------- | -------------- | ---------------- | ---------------------------------- |
| `cluster_name`        | `string`       | (required)       | Cluster name, used in tags & names |
| `region`              | `string`       | (required)       | AWS region                         |
| `az`                  | `string`       | (required)       | Single AZ for subnets and NAT GW   |
| `cidr`                | `string`       | `"10.0.0.0/16"`  | VPC CIDR                           |
| `public_subnet_cidr`  | `string`       | `"10.0.0.0/24"`  | Public subnet CIDR                 |
| `private_subnet_cidr` | `string`       | `"10.0.16.0/20"` | Private subnet CIDR                |
| `tags`                | `map(string)`  | `{}`             | Extra tags merged into resources   |
| `worker_replicas`     | `number`       | `2`              | One EIP allocated per worker       |

## Outputs

- `vpc_id`
- `public_subnet_id`
- `private_subnet_id`
- `nat_gateway_id`
- `igw_id`
- `worker_eip_allocation_ids` — list, length = `worker_replicas`
- `worker_eip_public_ips` — list, length = `worker_replicas`
