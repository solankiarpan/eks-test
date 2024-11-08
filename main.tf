# Provider configuration
provider "aws" {
  region = "us-west-2"
}

# Variables
variable "environment" {
  description = "Environment name"
  default     = "prod"
}

variable "vpc_primary_cidr" {
  description = "Primary CIDR block for VPC"
  default     = "10.0.0.0/16"
}

variable "vpc_secondary_cidrs" {
  description = "List of secondary CIDR blocks for VPC"
  type        = list(string)
  default     = ["10.1.0.0/16", "10.2.0.0/16"]  # Changed to use 10.x.x.x range
}

variable "cluster_version" {
  description = "Kubernetes version"
  default     = "1.28"
}

variable "node_instance_type" {
  description = "EC2 instance type for node groups"
  default     = "t3.medium"
}

# VPC Resource
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_primary_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.environment}-vpc"
    Environment = var.environment
  }
}

# Secondary CIDR blocks
resource "aws_vpc_ipv4_cidr_block_association" "secondary_cidrs" {
  count      = length(var.vpc_secondary_cidrs)
  vpc_id     = aws_vpc.main.id
  cidr_block = var.vpc_secondary_cidrs[count.index]
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.environment}-igw"
    Environment = var.environment
  }
}

# Availability Zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Public Subnets in Primary CIDR
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_primary_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.environment}-public-subnet-${count.index + 1}"
    Environment = var.environment
    Type        = "Public"
  }
}

# Private Subnets in Primary CIDR
resource "aws_subnet" "private_primary" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_primary_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name        = "${var.environment}-private-primary-subnet-${count.index + 1}"
    Environment = var.environment
    Type        = "Private"
  }
}

# Private Subnets in Secondary CIDRs
resource "aws_subnet" "private_secondary" {
  count             = length(var.vpc_secondary_cidrs) * 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(
    var.vpc_secondary_cidrs[floor(count.index / 2)],
    8,
    count.index % 2
  )
  availability_zone = data.aws_availability_zones.available.names[count.index % 2]

  depends_on = [aws_vpc_ipv4_cidr_block_association.secondary_cidrs]

  tags = {
    Name        = "${var.environment}-private-secondary-subnet-${count.index + 1}"
    Environment = var.environment
    Type        = "Private"
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "${var.environment}-nat-eip"
    Environment = var.environment
  }
}

# NAT Gateway
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name        = "${var.environment}-nat-gateway"
    Environment = var.environment
  }
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.environment}-public-rt"
    Environment = var.environment
  }
}

# Private Route Table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name        = "${var.environment}-private-rt"
    Environment = var.environment
  }
}

# Public Route Table Association
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private Route Table Associations for Primary CIDR Subnets
resource "aws_route_table_association" "private_primary" {
  count          = length(aws_subnet.private_primary)
  subnet_id      = aws_subnet.private_primary[count.index].id
  route_table_id = aws_route_table.private.id
}

# Private Route Table Associations for Secondary CIDR Subnets
resource "aws_route_table_association" "private_secondary" {
  count          = length(aws_subnet.private_secondary)
  subnet_id      = aws_subnet.private_secondary[count.index].id
  route_table_id = aws_route_table.private.id
}

# Outputs
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_primary_subnet_ids" {
  value = aws_subnet.private_primary[*].id
}

output "private_secondary_subnet_ids" {
  value = aws_subnet.private_secondary[*].id
}