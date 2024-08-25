#!/usr/bin/make

aws_command=aws
helmfile_command=HELM_DIFF_USE_UPGRADE_DRY_RUN=true helmfile
kubectl_command=kubectl
terraform_command=terraform

kubernetes_path=kubernetes
model_repository_path=model_repository
terraform_path=terraform

# apply

.PHONY: default
default: apply

.PHONY: apply
apply: terraform kubeconfig triton_model_repository kubernetes

.PHONY: terraform
terraform:
	$(terraform_command) -chdir=$(terraform_path) init
	$(terraform_command) -chdir=$(terraform_path) apply -auto-approve
	$(terraform_command) -chdir=$(terraform_path) output -json > $(kubernetes_path)/terraform_output.json

.PHONY: kubeconfig
kubeconfig:
	$(aws_command) eks update-kubeconfig \
	--region $(shell $(terraform_command) -chdir=$(terraform_path) output -raw region) \
	--name $(shell $(terraform_command) -chdir=$(terraform_path) output -raw eks_cluster_name) \
	--alias $(shell $(terraform_command) -chdir=$(terraform_path) output -raw eks_cluster_name)

.PHONY: triton_model_repository
triton_model_repository:
	aws s3 sync $(model_repository_path) \
	s3://$(shell $(terraform_command) -chdir=$(terraform_path) output -raw triton_s3_bucket_id)/model_repository

.PHONY: kubernetes
kubernetes:
	cd $(kubernetes_path) && $(helmfile_command) apply

# observe

.PHONY: port_forward
port_forward:
	$(kubectl_command) -n monitoring port-forward service/kube-prometheus-stack-grafana 8080:80

# re-run

.PHONY: client
client:
	cd $(kubernetes_path) && $(helmfile_command) sync -l name=triton-client

# destroy

.PHONY: destroy
destroy: kubernetes_destroy terraform_destroy

.PHONY: kubernetes_destroy
kubernetes_destroy:
	cd $(kubernetes_path) && $(helmfile_command) destroy

.PHONY: terraform_destroy
terraform_destroy:
	$(terraform_command) -chdir=$(terraform_path) init
	$(terraform_command) -chdir=$(terraform_path) destroy -auto-approve
