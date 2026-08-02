#!/bin/bash

# Configurações
BACKUP_FILE="backup-gitea"  # Pode ser um arquivo .tar.gz ou diretório
VOLUME_ROOT="./volume-gitea"  # ALTERE PARA O SEU DIRETÓRIO DE VOLUMES
LOG_FILE="/tmp/restore_gitea.log"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_success() {
    log "${GREEN}✓ $1${NC}"
}

log_error() {
    log "${RED}✗ $1${NC}"
}

log_warning() {
    log "${YELLOW}⚠ $1${NC}"
}

# Verifica se o arquivo de backup existe
if [ -z "$BACKUP_FILE" ]; then
    echo "Uso: $0 /caminho/para/backup.tar.gz ou /caminho/para/diretorio"
    echo "Exemplo: $0 /backups/gitea_backup_20240101_120000.tar.gz"
    exit 1
fi

# Função para restaurar
restore_backup() {
    log "========================================="
    log "INICIANDO RESTAURAÇÃO DO GITEA 1.26.2"
    log "========================================="
    
    # Verifica se é arquivo ou diretório
    if [ -f "$BACKUP_FILE" ] && [[ "$BACKUP_FILE" == *.tar.gz ]]; then
        log "Extraindo arquivo de backup: $BACKUP_FILE"
        local temp_dir="/tmp/gitea_restore_$$"
        mkdir -p "$temp_dir"
        tar -xzf "$BACKUP_FILE" -C "$temp_dir"
        BACKUP_DIR=$(find "$temp_dir" -maxdepth 1 -name "gitea_backup_*" -type d | head -1)
        if [ -z "$BACKUP_DIR" ]; then
            # Se não encontrar o diretório, usa o conteúdo extraído
            BACKUP_DIR="$temp_dir"
        fi
    elif [ -d "$BACKUP_FILE" ]; then
        BACKUP_DIR="$BACKUP_FILE"
    else
        log_error "Formato de backup inválido"
        exit 1
    fi
    
    if [ ! -d "$BACKUP_DIR" ]; then
        log_error "Diretório de backup não encontrado"
        exit 1
    fi
    
    log "Usando backup: $BACKUP_DIR"
    log "Conteúdo do backup:"
    ls -la "$BACKUP_DIR" | while read line; do
        log "  $line"
    done
    
    # Para os containers
    log "Parando containers..."
    docker-compose down 2>/dev/null || true
    
    # Faz backup dos dados atuais
    local current_backup="/tmp/gitea_current_backup_$$"
    mkdir -p "$current_backup"
    if [ -d "${VOLUME_ROOT}/gitea_data" ]; then
        log "Fazendo backup dos dados atuais para: $current_backup"
        cp -r "${VOLUME_ROOT}/gitea_data" "$current_backup/"
    fi
    
    # Restaura os dados
    log "Restaurando dados..."
    
    # Restaura banco de dados
    if [ -f "${BACKUP_DIR}/gitea.db" ]; then
        mkdir -p "${VOLUME_ROOT}/gitea_data/gitea"
        cp "${BACKUP_DIR}/gitea.db" "${VOLUME_ROOT}/gitea_data/gitea/gitea.db"
        log_success "Banco de dados restaurado"
    elif [ -f "${BACKUP_DIR}/data/gitea.db" ]; then
        # Compatibilidade com formato antigo
        mkdir -p "${VOLUME_ROOT}/gitea_data/gitea"
        cp "${BACKUP_DIR}/data/gitea.db" "${VOLUME_ROOT}/gitea_data/gitea/gitea.db"
        log_success "Banco de dados restaurado (formato antigo)"
    else
        log_error "Arquivo do banco de dados não encontrado no backup"
    fi
    
    # Restaura configuração
    if [ -f "${BACKUP_DIR}/gitea_conf.tar.gz" ]; then
        mkdir -p "${VOLUME_ROOT}/gitea_data/gitea"
        tar -xzf "${BACKUP_DIR}/gitea_conf.tar.gz" -C "${VOLUME_ROOT}/gitea_data/gitea"
        log_success "Configuração restaurada"
    elif [ -f "${BACKUP_DIR}/config.tar.gz" ]; then
        mkdir -p "${VOLUME_ROOT}/gitea_data/gitea"
        tar -xzf "${BACKUP_DIR}/config.tar.gz" -C "${VOLUME_ROOT}/gitea_data/gitea"
        log_success "Configuração restaurada (formato antigo)"
    else
        log_warning "Arquivo de configuração não encontrado no backup"
    fi
    
    # Restaura repositórios - CORRIGIDO PARA GITEA 1.26.2
    if [ -f "${BACKUP_DIR}/repositories.tar.gz" ]; then
        mkdir -p "${VOLUME_ROOT}/gitea_data"
        tar -xzf "${BACKUP_DIR}/repositories.tar.gz" -C "${VOLUME_ROOT}/gitea_data"
        log_success "Repositórios restaurados em: ${VOLUME_ROOT}/gitea_data/git/repositories"
    elif [ -f "${BACKUP_DIR}/git_data.tar.gz" ]; then
        # Restaura o diretório git completo
        mkdir -p "${VOLUME_ROOT}/gitea_data"
        tar -xzf "${BACKUP_DIR}/git_data.tar.gz" -C "${VOLUME_ROOT}/gitea_data"
        log_success "Diretório git restaurado"
    else
        # Tenta restaurar de outros formatos (compatibilidade)
        if [ -f "${BACKUP_DIR}/gitea-repositories.tar.gz" ]; then
            mkdir -p "${VOLUME_ROOT}/gitea_data/gitea/data"
            tar -xzf "${BACKUP_DIR}/gitea-repositories.tar.gz" -C "${VOLUME_ROOT}/gitea_data/gitea/data"
            log_success "Repositórios restaurados (formato antigo)"
        else
            log_warning "Repositórios não encontrados no backup"
        fi
    fi
    
    # Restaura dados adicionais
    if [ -f "${BACKUP_DIR}/gitea_data.tar.gz" ]; then
        mkdir -p "${VOLUME_ROOT}/gitea_data/gitea"
        tar -xzf "${BACKUP_DIR}/gitea_data.tar.gz" -C "${VOLUME_ROOT}/gitea_data/gitea"
        log_success "Dados adicionais restaurados"
    elif [ -f "${BACKUP_DIR}/gitea_full.tar.gz" ]; then
        mkdir -p "${VOLUME_ROOT}/gitea_data"
        tar -xzf "${BACKUP_DIR}/gitea_full.tar.gz" -C "${VOLUME_ROOT}/gitea_data"
        log_success "Backup completo restaurado"
    else
        log_warning "Dados adicionais não encontrados no backup"
    fi
    
    # Restaura runner
    if [ -f "${BACKUP_DIR}/runner_data.tar.gz" ]; then
        mkdir -p "${VOLUME_ROOT}"
        tar -xzf "${BACKUP_DIR}/runner_data.tar.gz" -C "${VOLUME_ROOT}"
        log_success "Dados do runner restaurados"
    else
        log_warning "Dados do runner não encontrados no backup"
    fi
    
    # Restaura registry
    if [ -f "${BACKUP_DIR}/registry_data.tar.gz" ]; then
        mkdir -p "${VOLUME_ROOT}"
        tar -xzf "${BACKUP_DIR}/registry_data.tar.gz" -C "${VOLUME_ROOT}"
        log_success "Dados do registry restaurados"
    else
        log_warning "Dados do registry não encontrados no backup"
    fi
    
    # Corrige permissões
    log "Corrigindo permissões..."
    chown -R 1000:1000 "${VOLUME_ROOT}/gitea_data" 2>/dev/null || true
    chown -R 1000:1000 "${VOLUME_ROOT}/gitea_runner_data" 2>/dev/null || true
    chown -R 1000:1000 "${VOLUME_ROOT}/registry_data" 2>/dev/null || true
    
    # Inicia os containers
    log "Iniciando containers..."
    docker compose up -d
    
    log_success "Restauração concluída!"
    log "========================================="
}

# Executa a restauração
restore_backup