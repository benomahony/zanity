resource "aws_s3_bucket_acl" "public" {
  acl = "public-read"
}

resource "aws_s3_bucket_acl" "private" {
  acl = "private"
}
