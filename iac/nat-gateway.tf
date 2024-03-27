# allocate elastic ip. this eip will be used for the nat-gateway in the public subnet az1 
resource "aws_eip" "eip1" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-eip"
  }
}

# create nat gateway in public subnet az1
resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.eip1.id
  subnet_id     = aws_subnet.public_subnet_az1.id

  tags = {
    Name = "${var.project_name}-${var.environment}-ngw"
  }

  # to ensure proper ordering, it is recommended to add an explicit dependency
  # on the internet gateway for the vpc
  depends_on = [aws_internet_gateway.internet_gateway]
}


# create private route table az1 and add route through nat gateway az1
resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateway.id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-privateRT"
  }
}


# associate private data subnet az1 with private route table az1
resource "aws_route_table_association" "private_data_subnet_az1_rt_association" {
  subnet_id      = aws_subnet.private_data_subnet_az1.id
  route_table_id = aws_route_table.private_route_table.id
}


# associate private data subnet az2 with private route table az2
resource "aws_route_table_association" "private_data_subnet_az2_rt_association" {
  subnet_id      = aws_subnet.private_data_subnet_az2.id
  route_table_id = aws_route_table.private_route_table.id
}