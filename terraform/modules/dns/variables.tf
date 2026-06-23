variable "subdomain" {
  description = "Subdomain delegated to this Route 53 zone, e.g. vigil.webtechhq.com. Must be delegated via an NS record at the external DNS host that owns the parent apex domain."
  type        = string
}

variable "webhook_subdomain" {
  description = "soc-daemon webhook hostname, e.g. hooks.vigil.webtechhq.com. Must be a subdomain of var.subdomain."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
