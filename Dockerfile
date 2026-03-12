# Usa a imagem oficial otimizada em Alpine do Gitea
FROM gitea/gitea:latest

# Se precisar instalar pacotes extras para o host do container futuramente, 
# pode adicionar os comandos abaixo:
# RUN apk --no-cache add \
#      suas-dependencias
