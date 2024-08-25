variable "name" {
  type = string
}

variable "tags" {
  type = map(string)
  default = {}
}

variable "region" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}
