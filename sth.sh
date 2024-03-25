gcloud sql connect my-mysql-instance --user=root
zip -r function-source.zip requirements.txt $(find src -type f ! -path "src/aaa/*")
terraform plan -var-file="secrets.tfvars"