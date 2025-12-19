# GT2-birt

`docker builder prune`

`az login`

`az acr login --name ekorent`

`docker build --tag=birt .`

`docker run -d -p 8080:8080 birt`

`docker rmi ekorent.azurecr.io/birt:0.0.2`

`docker tag birt ekorent.azurecr.io/birt:0.0.2`

`docker push ekorent.azurecr.io/birt:0.0.2`
