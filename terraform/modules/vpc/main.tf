data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs    = slice(data.aws_availability_zones.available.names, 0, 2)
  vpc_id = var.existing_vpc_id != null ? var.existing_vpc_id : aws_vpc.this[0].id
}

# ──────────────────────────────────────────────
# VPC (create only if no existing VPC ID provided)
# ──────────────────────────────────────────────
resource "aws_vpc" "this" {
  count = var.existing_vpc_id == null ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.name}-vpc"
  })
}

# ──────────────────────────────────────────────
# Public Subnets (only if creating new VPC)
# ──────────────────────────────────────────────
resource "aws_subnet" "public" {
  count = var.existing_vpc_id == null ? length(local.azs) : 0

  vpc_id                  = local.vpc_id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                                        = "${var.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ──────────────────────────────────────────────
# Data source for existing public subnets (bootstrap VPC)
# ──────────────────────────────────────────────
data "aws_subnets" "public_bootstrap" {
  count = var.existing_vpc_id != null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [var.existing_vpc_id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# ──────────────────────────────────────────────
# Private Subnets
# ──────────────────────────────────────────────
resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = local.vpc_id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 32)
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"
  })
}



# ──────────────────────────────────────────────
# Private Data Subnets (for RDS)
# ──────────────────────────────────────────────
resource "aws_subnet" "private_data" {
  count = length(local.azs)

  vpc_id            = local.vpc_id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 96)
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-private-data-${local.azs[count.index]}"
    Tier = "data"
  })
}

# ──────────────────────────────────────────────
# Internet Gateway (only if creating new VPC)
# ──────────────────────────────────────────────
resource "aws_internet_gateway" "this" {
  count = var.existing_vpc_id == null ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name}-igw"
  })
}

# ──────────────────────────────────────────────
# NAT Gateway (single AZ to save cost)
# ──────────────────────────────────────────────
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-nat-eip"
  })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = var.existing_vpc_id == null ? aws_subnet.public[0].id : data.aws_subnets.public_bootstrap[0].ids[0]

  tags = merge(var.tags, {
    Name = "${var.name}-nat"
  })

  depends_on = [aws_internet_gateway.this]
}

# ──────────────────────────────────────────────
# Route Tables
# ──────────────────────────────────────────────
resource "aws_route_table" "public" {
  count = var.existing_vpc_id == null ? 1 : 0

  vpc_id = local.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = merge(var.tags, {
    Name = "${var.name}-public-rt"
  })
}

resource "aws_route_table" "private" {
  vpc_id = local.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = merge(var.tags, {
    Name = "${var.name}-private-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = var.existing_vpc_id == null ? length(local.azs) : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "private" {
  count = length(local.azs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_data" {
  count = length(local.azs)

  subnet_id      = aws_subnet.private_data[count.index].id
  route_table_id = aws_route_table.private.id
}

# ──────────────────────────────────────────────
# VPC Endpoints
# ──────────────────────────────────────────────

# Security Group for Interface Endpoints
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name}-vpc-endpoints-sg"
  description = "Security group for VPC endpoints"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name}-vpc-endpoints-sg"
  })
}

# S3 Gateway Endpoint
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    var.existing_vpc_id == null ? [aws_route_table.public[0].id] : [],
    [aws_route_table.private.id]
  )

  tags = merge(var.tags, {
    Name = "${var.name}-vpc-endpoint-s3"
  })
}

# Interface Endpoints (SSM removed — SSH-only access model)
locals {
  interface_services = [
    "ecr.api",
    "ecr.dkr",
    "sts",
    "logs"
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_services)

  vpc_id             = local.vpc_id
  service_name       = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type  = "Interface"

  subnet_ids = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.name}-vpc-endpoint-${each.key}"
  })
}
