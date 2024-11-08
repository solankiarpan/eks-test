# [Previous VPC configuration remains unchanged]

# EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster" {
  name = "${var.environment}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# EKS Node Group IAM Role
resource "aws_iam_role" "eks_nodes" {
  name = "${var.environment}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}

# EKS Cluster Security Group
resource "aws_security_group" "eks_cluster" {
  name        = "${var.environment}-eks-cluster-sg"
  description = "Security group for EKS cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-eks-cluster-sg"
    Environment = var.environment
  }
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = "${var.environment}-eks-cluster"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  vpc_config {
    security_group_ids = [aws_security_group.eks_cluster.id]
    # Use all private subnets (primary and secondary)
    subnet_ids = concat(
      aws_subnet.private_primary[*].id,
      aws_subnet.private_secondary[*].id
    )
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_vpc_ipv4_cidr_block_association.secondary_cidrs
  ]

  tags = {
    Name        = "${var.environment}-eks-cluster"
    Environment = var.environment
  }
}

# Node Groups - one for each CIDR block's subnets
# Primary CIDR Node Group
resource "aws_eks_node_group" "primary" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.environment}-primary-ng"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private_primary[*].id

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }

  instance_types = [var.node_instance_type]

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry
  ]

  tags = {
    Name        = "${var.environment}-primary-ng"
    Environment = var.environment
  }
}

# Secondary CIDR Node Groups
resource "aws_eks_node_group" "secondary" {
  count = length(var.vpc_secondary_cidrs)

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.environment}-secondary-ng-${count.index + 1}"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  
  # Select the appropriate secondary subnets for each CIDR block
  subnet_ids = [
    aws_subnet.private_secondary[count.index * 2].id,
    aws_subnet.private_secondary[count.index * 2 + 1].id
  ]

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }

  instance_types = [var.node_instance_type]

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry
  ]

  tags = {
    Name        = "${var.environment}-secondary-ng-${count.index + 1}"
    Environment = var.environment
  }
}

# Additional required tags for EKS subnets
resource "aws_ec2_tag" "private_primary_subnet_tags" {
  count       = length(aws_subnet.private_primary)
  resource_id = aws_subnet.private_primary[count.index].id
  key         = "kubernetes.io/cluster/${var.environment}-eks-cluster"
  value       = "shared"
}

resource "aws_ec2_tag" "private_secondary_subnet_tags" {
  count       = length(aws_subnet.private_secondary)
  resource_id = aws_subnet.private_secondary[count.index].id
  key         = "kubernetes.io/cluster/${var.environment}-eks-cluster"
  value       = "shared"
}

# Additional outputs for EKS
output "eks_cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "eks_cluster_name" {
  value = aws_eks_cluster.main.name
}

output "eks_cluster_certificate_authority" {
  value = aws_eks_cluster.main.certificate_authority[0].data
}

output "eks_node_groups" {
  value = {
    primary = aws_eks_node_group.primary.id
    secondary = aws_eks_node_group.secondary[*].id
  }
}