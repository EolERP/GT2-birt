`docker builder prune`

`az login`

`az acr login --name creditshare`

`docker build --tag=birt .`

`docker run -d -p 8080:8080 birt`

`docker rmi creditshare.azurecr.io/birt:0.0.2`

`docker tag birt creditshare.azurecr.io/birt:0.0.2`

`docker push creditshare.azurecr.io/birt:0.0.2`

