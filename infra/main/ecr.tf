resource "aws_ecr_repository" "this" {
  for_each = toset(["api", "web"])

  name = "${var.project}/${each.key}"

  # Tags are git SHAs; immutability guarantees a SHA always means one image.
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # destroy must not fail on a non-empty repo

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        # "any" must be the last (highest-number) rule.
        rulePriority = 2
        description  = "Keep only the newest 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}
