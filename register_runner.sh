#!/bin/bash

# Este script automatiza o processo de registro do runner do Gitea.
# Ele extrai o token gerado pelo Gitea e o utiliza para registrar o runner.

echo "========================================="
echo "⚙️  Registrando o Gitea Runner..."
echo "========================================="

# Espera alguns segundos para garantir que o Gitea esteja inicializado
# (Descomente a linha abaixo se rodar o script logo após o docker-compose up)
# sleep 5

echo "1️⃣  Gerando token para registrar o runner..."
TOKEN=$(docker exec gitea su git -c "gitea --config /data/gitea/conf/app.ini actions generate-runner-token")

if [ -z "$TOKEN" ]; then
    echo "❌ Erro: Não foi possível gerar o token do runner."
    echo "Verifique se o container 'gitea' está rodando."
    exit 1
fi

echo "✅ Token gerado com sucesso!"

echo "2️⃣  Registrando o container gitea_runner..."
docker exec gitea_runner act_runner register \
    --instance http://notebook-server:3000 \
    --token "$TOKEN" \
    --no-interactive

if [ $? -ne 0 ]; then
    echo "❌ Erro: Falha ao registrar o runner."
    exit 1
fi

echo "✅ Runner registrado com sucesso!"

echo "3️⃣  Iniciando o runner em modo daemon..."
# Usa o parâmetro -d do docker exec para rodar o processo em background
docker exec -d gitea_runner act_runner daemon

echo "========================================="
echo "🚀 Tudo pronto! O runner já está ativo."
echo "========================================="
