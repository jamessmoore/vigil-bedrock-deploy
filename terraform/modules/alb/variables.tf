variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "certificate_arn" {
  type = string
}

variable "webhook_subdomain" {
  description = "Host-header match for the soc-daemon webhook rule, e.g. hooks.vigil.webtechhq.com"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
