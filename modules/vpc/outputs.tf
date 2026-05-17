output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_id" {
  description = "ID of the public subnet."
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet."
  value       = aws_subnet.private.id
}

output "nat_gateway_id" {
  description = "ID of the NAT Gateway."
  value       = aws_nat_gateway.this.id
}

output "igw_id" {
  description = "ID of the Internet Gateway."
  value       = aws_internet_gateway.this.id
}

output "worker_eip_allocation_ids" {
  description = "Allocation IDs of EIPs reserved for worker nodes. attach-worker-eips.sh consumes this list."
  value       = aws_eip.worker[*].id
}

output "worker_eip_public_ips" {
  description = "Public IPv4 addresses of worker EIPs (pre-association — same address survives reassociation)."
  value       = aws_eip.worker[*].public_ip
}
