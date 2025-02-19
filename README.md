`docker builder prune`

`az login`

`az acr login --name credixcz`

`docker build --tag=birt .`

`docker run -d -p 8080:8080 birt`

`docker rmi credixcz.azurecr.io/birt:0.0.2`

`docker tag birt credixcz.azurecr.io/birt:0.0.2`

`docker push credixcz.azurecr.io/birt:0.0.2`

