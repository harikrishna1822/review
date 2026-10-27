# Optional network for a test environment: tasks run in a private subnet; all their traffic
# leaves through one NAT gateway with an Elastic IP, the IP Snowflake's network policy allows.

data "aws_availability_zones" "available" {
  count = var.create_network ? 1 : 0
  state = "available"
}

resource "aws_vpc" "this" {
  count                = var.create_network ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  count             = var.create_network ? 1 : 0
  vpc_id            = aws_vpc.this[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone = data.aws_availability_zones.available[0].names[0]
  tags              = { Name = "${local.name}-public" }
}

resource "aws_subnet" "private" {
  count             = var.create_network ? 1 : 0
  vpc_id            = aws_vpc.this[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone = data.aws_availability_zones.available[0].names[0]
  tags              = { Name = "${local.name}-private" }
}

resource "aws_eip" "nat" {
  count  = var.create_network ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${local.name}-nat" }
}

resource "aws_nat_gateway" "this" {
  count         = var.create_network ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = local.name }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = var.create_network ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }
  tags = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  count          = var.create_network ? 1 : 0
  subnet_id      = aws_subnet.private[0].id
  route_table_id = aws_route_table.private[0].id
}

# S3 traffic (Iceberg data files) through a free gateway endpoint instead of the NAT gateway.
# Snowflake vends credentials for the bucket; requests stay signed, only the path changes.
resource "aws_vpc_endpoint" "s3" {
  count             = var.create_network ? 1 : 0
  vpc_id            = aws_vpc.this[0].id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private[0].id]
  tags              = { Name = local.name }
}

resource "aws_security_group" "task" {
  name        = local.name
  description = "dbt-horizon tasks: no inbound, HTTPS out (git, Snowflake, S3)"
  vpc_id      = local.vpc_id
  egress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = local.name }
}
