# gerando token para registrar runner
docker exec gitea su git -c "gitea --config /data/gitea/conf/app.ini actions generate-runner-token"

docker container exec -it gitea_runner bash
# registrar container
act_runner register --instance http://server:3000 --token <token> --no-interactive

# rodar como daemon
docker compose up -d runner
