#!/bin/bash

# Configurações
BACKUP_ROOT="/home/eloy/Documents/repos/backup-gitea"  # ALTERE PARA O SEU DIRETÓRIO
VOLUME_ROOT="/home/eloy/Documents/repos/docker-volumes"  # ALTERE PARA O SEU DIRETÓRIO DE VOLUMES
RETENTION_DAYS=30
BACKUP_DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${BACKUP_ROOT}/gitea_backup_${BACKUP_DATE}"
LOG_FILE="${BACKUP_ROOT}/backup_log_${BACKUP_DATE}.log"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Função para log
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

# Função para verificar se o container existe e está rodando
check_container() {
    local container=$1
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            log_warning "Container $container existe mas está parado"
            return 1
        else
            log_error "Container $container não encontrado"
            return 2
        fi
    fi
    return 0
}

# Função para criar backup do banco de dados (SQLite)
backup_database() {
    log "Iniciando backup do banco de dados SQLite..."
    
    local db_file="${VOLUME_ROOT}/gitea_data/gitea/gitea.db"
    local backup_file="${BACKUP_DIR}/gitea.db"
    
    if [ -f "$db_file" ]; then
        # Verifica se o container está rodando para fazer backup consistente
        if docker ps --format '{{.Names}}' | grep -q "^gitea$"; then
            # Usa o sqlite3 dentro do container para backup consistente
            docker exec gitea sh -c "sqlite3 /data/gitea/gitea.db '.backup /tmp/gitea_backup.db'" 2>/dev/null
            docker cp gitea:/tmp/gitea_backup.db "$backup_file" 2>/dev/null
            docker exec gitea rm -f /tmp/gitea_backup.db 2>/dev/null
            
            if [ -f "$backup_file" ]; then
                local size=$(du -h "$backup_file" | cut -f1)
                log_success "Backup do banco de dados criado: $backup_file (tamanho: $size)"
                return 0
            fi
        fi
        
        # Fallback: cópia direta se o sqlite3 não funcionar
        log_warning "Tentando cópia direta do banco de dados..."
        if cp "$db_file" "$backup_file" 2>/dev/null; then
            local size=$(du -h "$backup_file" | cut -f1)
            log_success "Backup do banco de dados criado (cópia direta): $backup_file (tamanho: $size)"
            return 0
        else
            log_error "Falha ao criar backup do banco de dados"
            return 1
        fi
    else
        log_error "Arquivo do banco de dados não encontrado: $db_file"
        return 1
    fi
}

# Função para criar backup das configurações
backup_config() {
    log "Iniciando backup da configuração..."
    
    local config_dir="${VOLUME_ROOT}/gitea_data/gitea/conf"
    local backup_file="${BACKUP_DIR}/gitea_conf.tar.gz"
    
    if [ -d "$config_dir" ] && [ -n "$(ls -A "$config_dir" 2>/dev/null)" ]; then
        tar -czf "$backup_file" -C "${VOLUME_ROOT}/gitea_data/gitea" "conf" 2>/dev/null
        
        if [ -f "$backup_file" ]; then
            local size=$(du -h "$backup_file" | cut -f1)
            log_success "Backup da configuração criado: $backup_file (tamanho: $size)"
            return 0
        else
            log_error "Falha ao criar backup da configuração"
            return 1
        fi
    else
        log_warning "Diretório de configuração não encontrado ou vazio: $config_dir"
    fi
    return 0
}

# Função para criar backup dos repositórios - CORRIGIDO PARA GITEA 1.26.2
backup_repositories() {
    log "Iniciando backup dos repositórios..."
    
    # Localização correta dos repositórios no Gitea 1.26.2
    local repo_dir="${VOLUME_ROOT}/gitea_data/git/repositories"
    local backup_file="${BACKUP_DIR}/repositories.tar.gz"
    
    if [ -d "$repo_dir" ] && [ -n "$(ls -A "$repo_dir" 2>/dev/null)" ]; then
        log "Encontrados repositórios em: $repo_dir"
        local repo_count=$(find "$repo_dir" -name "*.git" -type d 2>/dev/null | wc -l)
        log "Total de repositórios encontrados: $repo_count"
        
        # Compacta os repositórios mantendo a estrutura
        tar -czf "$backup_file" -C "${VOLUME_ROOT}/gitea_data" "git/repositories" 2>/dev/null
        
        if [ -f "$backup_file" ]; then
            local size=$(du -h "$backup_file" | cut -f1)
            log_success "Backup dos repositórios criado: $backup_file (tamanho: $size)"
            log "  - $repo_count repositórios incluídos"
            return 0
        else
            log_error "Falha ao compactar os repositórios"
            return 1
        fi
    else
        # Tenta outros locais possíveis como fallback
        local fallback_dirs=(
            "${VOLUME_ROOT}/gitea_data/gitea/data/gitea-repositories"
            "${VOLUME_ROOT}/gitea_data/gitea/repositories"
            "${VOLUME_ROOT}/gitea_data/repositories"
        )
        
        for fallback_dir in "${fallback_dirs[@]}"; do
            if [ -d "$fallback_dir" ] && [ -n "$(ls -A "$fallback_dir" 2>/dev/null)" ]; then
                log_warning "Repositórios encontrados em local alternativo: $fallback_dir"
                tar -czf "$backup_file" -C "$(dirname "$fallback_dir")" "$(basename "$fallback_dir")" 2>/dev/null
                
                if [ -f "$backup_file" ]; then
                    local size=$(du -h "$backup_file" | cut -f1)
                    log_success "Backup dos repositórios criado (local alternativo): $backup_file (tamanho: $size)"
                    return 0
                fi
            fi
        done
        
        log_warning "Nenhum repositório encontrado para backup"
    fi
    
    return 0
}

# Função para criar backup dos dados do Gitea (outros diretórios importantes)
backup_gitea_data() {
    log "Iniciando backup de dados adicionais do Gitea..."
    
    local backup_file="${BACKUP_DIR}/gitea_data.tar.gz"
    local gitea_base="${VOLUME_ROOT}/gitea_data/gitea"
    
    # Diretórios importantes para backup (excluindo conf, gitea.db e dados que já foram backup)
    local dirs_to_backup=(
        "actions_artifacts"
        "actions_log"
        "attachments"
        "avatars"
        "indexers"
        "packages"
        "repo-archive"
        "repo-avatars"
        "sessions"
        # "home" - normalmente não precisa de backup
        # "log" - logs não precisam de backup
        # "tmp" - temporários não precisam de backup
        # "jwt" - tokens JWT são regenerados
        # "queues" - filas são temporárias
    )
    
    local temp_dir=$(mktemp -d)
    local has_data=false
    
    for dir in "${dirs_to_backup[@]}"; do
        local src_dir="${gitea_base}/${dir}"
        if [ -d "$src_dir" ] && [ -n "$(ls -A "$src_dir" 2>/dev/null)" ]; then
            mkdir -p "$temp_dir/$dir"
            cp -r "$src_dir"/* "$temp_dir/$dir/" 2>/dev/null
            has_data=true
            local dir_size=$(du -sh "$src_dir" 2>/dev/null | cut -f1)
            log "  - $dir: $dir_size"
        fi
    done
    
    if [ "$has_data" = true ]; then
        tar -czf "$backup_file" -C "$temp_dir" . 2>/dev/null
        
        if [ -f "$backup_file" ]; then
            local size=$(du -h "$backup_file" | cut -f1)
            log_success "Backup dos dados adicionais criado: $backup_file (tamanho: $size)"
            rm -rf "$temp_dir"
            return 0
        else
            log_error "Falha ao criar backup dos dados adicionais"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        log_warning "Nenhum dado adicional encontrado para backup"
        rm -rf "$temp_dir"
    fi
    
    return 0
}

# Função para criar backup do diretório git (inclui repositórios e hooks)
backup_git_data() {
    log "Iniciando backup do diretório git..."
    
    local git_dir="${VOLUME_ROOT}/gitea_data/git"
    local backup_file="${BACKUP_DIR}/git_data.tar.gz"
    
    if [ -d "$git_dir" ] && [ -n "$(ls -A "$git_dir" 2>/dev/null)" ]; then
        tar -czf "$backup_file" -C "${VOLUME_ROOT}/gitea_data" "git" 2>/dev/null
        
        if [ -f "$backup_file" ]; then
            local size=$(du -h "$backup_file" | cut -f1)
            log_success "Backup do diretório git criado: $backup_file (tamanho: $size)"
            return 0
        else
            log_error "Falha ao criar backup do diretório git"
            return 1
        fi
    else
        log_warning "Diretório git não encontrado: $git_dir"
    fi
    
    return 0
}

# Função para criar backup dos dados do runner
backup_runner() {
    log "Iniciando backup dos dados do runner..."
    
    local runner_dir="${VOLUME_ROOT}/gitea_runner_data"
    local backup_file="${BACKUP_DIR}/runner_data.tar.gz"
    
    if [ -d "$runner_dir" ] && [ -n "$(ls -A "$runner_dir" 2>/dev/null)" ]; then
        tar -czf "$backup_file" -C "$VOLUME_ROOT" "gitea_runner_data" 2>/dev/null
        
        if [ -f "$backup_file" ]; then
            local size=$(du -h "$backup_file" | cut -f1)
            log_success "Backup dos dados do runner criado: $backup_file (tamanho: $size)"
            return 0
        else
            log_warning "Falha ao criar backup dos dados do runner"
        fi
    else
        log_warning "Diretório do runner não encontrado ou vazio: $runner_dir"
    fi
    
    return 0
}

# Função para criar backup do registry
backup_registry() {
    log "Iniciando backup do registry..."
    
    local registry_dir="${VOLUME_ROOT}/registry_data"
    local backup_file="${BACKUP_DIR}/registry_data.tar.gz"
    
    if [ -d "$registry_dir" ] && [ -n "$(ls -A "$registry_dir" 2>/dev/null)" ]; then
        tar -czf "$backup_file" -C "$VOLUME_ROOT" "registry_data" 2>/dev/null
        
        if [ -f "$backup_file" ]; then
            local size=$(du -h "$backup_file" | cut -f1)
            log_success "Backup do registry criado: $backup_file (tamanho: $size)"
            return 0
        else
            log_warning "Falha ao criar backup do registry"
        fi
    else
        log_warning "Diretório do registry não encontrado ou vazio: $registry_dir"
    fi
    
    return 0
}

# Função para criar dump das variáveis de ambiente
backup_env() {
    log "Criando dump das variáveis de ambiente do compose..."
    
    local env_file="${BACKUP_DIR}/docker-compose.env"
    
    # Salva as variáveis de ambiente usadas no docker-compose
    cat > "$env_file" << EOF
# Backup das variáveis de ambiente do Gitea - $(date)
# Versão do Gitea: 1.26.2
DOMAIN=${DOMAIN:-notebook-server}
SSH_DOMAIN=${SSH_DOMAIN:-notebook-server}
HTTP_PORT=${HTTP_PORT:-3000}
SSH_PORT=${SSH_PORT:-2222}
VOLUME_ROOT=${VOLUME_ROOT}
GITEA__database__DB_TYPE=${GITEA__database__DB_TYPE:-sqlite3}
GITEA__actions__ENABLED=${GITEA__actions__ENABLED:-true}
USER_UID=${USER_UID:-1000}
USER_GID=${USER_GID:-1000}
GITEA_RUNNER_REGISTRATION_TOKEN=${GITEA_RUNNER_REGISTRATION_TOKEN:-<token_sera_gerado_automaticamente>}
EOF
    
    log_success "Dump das variáveis de ambiente criado: $env_file"
}

# Função para criar relatório do backup
create_report() {
    log "Criando relatório do backup..."
    
    local report_file="${BACKUP_DIR}/backup_report.txt"
    
    # Conta repositórios no backup
    local repo_count="0"
    if [ -f "${BACKUP_DIR}/repositories.tar.gz" ]; then
        repo_count=$(tar -tzf "${BACKUP_DIR}/repositories.tar.gz" 2>/dev/null | grep -c "\.git/$" || echo "0")
    fi
    
    cat > "$report_file" << EOF
=================================================================
RELATÓRIO DE BACKUP - GITEA 1.26.2
=================================================================
Data do backup: $(date '+%Y-%m-%d %H:%M:%S')
Diretório do backup: ${BACKUP_DIR}
Tamanho total: $(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)

ESTATÍSTICAS:
- Repositórios: $repo_count
- Banco de dados: $(du -sh "${BACKUP_DIR}/gitea.db" 2>/dev/null | cut -f1 || echo "N/A")
- Configurações: $(du -sh "${BACKUP_DIR}/gitea_conf.tar.gz" 2>/dev/null | cut -f1 || echo "N/A")

ARQUIVOS DE BACKUP:
$(ls -lh "${BACKUP_DIR}" 2>/dev/null | grep -v "^total" | sed 's/^/  /')

ESTRUTURA DO BACKUP:
$(tree "${BACKUP_DIR}" 2>/dev/null || ls -la "${BACKUP_DIR}" 2>/dev/null)

STATUS DOS CONTAINERS:
- Gitea Server: $(docker ps --format '{{.Names}}' | grep -q "^gitea$" && echo "✓ Rodando" || echo "✗ Parado/Offline")
- Gitea Runner: $(docker ps --format '{{.Names}}' | grep -q "^gitea_runner$" && echo "✓ Rodando" || echo "✗ Parado/Offline")
- Docker Registry: $(docker ps --format '{{.Names}}' | grep -q "^docker_registry$" && echo "✓ Rodando" || echo "✗ Parado/Offline")

TAMANHO DOS DIRETÓRIOS (no backup):
$(du -sh "${BACKUP_DIR}"/* 2>/dev/null | sed 's/^/  /')

Log completo disponível em: ${LOG_FILE}
=================================================================
EOF
    
    log_success "Relatório criado: $report_file"
}

# Função para verificar integridade do backup
verify_backup() {
    log "Verificando integridade do backup..."
    
    local issues=0
    
    # Verifica se o banco de dados foi backupado
    if [ -f "${BACKUP_DIR}/gitea.db" ]; then
        local db_size=$(du -h "${BACKUP_DIR}/gitea.db" | cut -f1)
        log_success "✓ Banco de dados: OK (tamanho: $db_size)"
    else
        log_error "✗ Banco de dados não encontrado no backup"
        ((issues++))
    fi
    
    # Verifica configuração
    if [ -f "${BACKUP_DIR}/gitea_conf.tar.gz" ]; then
        log_success "✓ Configuração: OK"
    else
        log_warning "⚠ Configuração não encontrada no backup"
    fi
    
    # Verifica repositórios
    if [ -f "${BACKUP_DIR}/repositories.tar.gz" ]; then
        local repo_size=$(du -h "${BACKUP_DIR}/repositories.tar.gz" | cut -f1)
        local repo_count=$(tar -tzf "${BACKUP_DIR}/repositories.tar.gz" 2>/dev/null | grep -c "\.git/$" || echo "0")
        log_success "✓ Repositórios: OK (tamanho: $repo_size, $repo_count repositórios)"
    else
        log_warning "⚠ Repositórios não encontrados no backup"
    fi
    
    # Verifica dados adicionais
    if [ -f "${BACKUP_DIR}/gitea_data.tar.gz" ]; then
        log_success "✓ Dados adicionais: OK"
    fi
    
    # Verifica diretório git
    if [ -f "${BACKUP_DIR}/git_data.tar.gz" ]; then
        log_success "✓ Diretório git: OK"
    fi
    
    if [ $issues -eq 0 ]; then
        log_success "Verificação concluída: Nenhum problema encontrado"
    else
        log_warning "Verificação concluída: $issues problema(s) encontrado(s)"
    fi
    
    return $issues
}

# Função para limpar backups antigos
cleanup_old_backups() {
    log "Limpando backups com mais de ${RETENTION_DAYS} dias..."
    
    local count=$(find "$BACKUP_ROOT" -maxdepth 1 -name "gitea_backup_*" -type d -mtime +${RETENTION_DAYS} 2>/dev/null | wc -l)
    
    if [ $count -gt 0 ]; then
        find "$BACKUP_ROOT" -maxdepth 1 -name "gitea_backup_*" -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} \; 2>/dev/null
        log_success "Removidos ${count} backup(s) antigo(s)"
    else
        log "Nenhum backup antigo para remover"
    fi
    
    # Remove arquivos .tar.gz antigos também
    count=$(find "$BACKUP_ROOT" -maxdepth 1 -name "gitea_backup_*.tar.gz" -mtime +${RETENTION_DAYS} 2>/dev/null | wc -l)
    if [ $count -gt 0 ]; then
        find "$BACKUP_ROOT" -maxdepth 1 -name "gitea_backup_*.tar.gz" -mtime +${RETENTION_DAYS} -exec rm -f {} \; 2>/dev/null
        log_success "Removidos ${count} arquivo(s) compactado(s) antigo(s)"
    fi
}

# Função principal
main() {
    log "========================================="
    log "INICIANDO BACKUP DO GITEA 1.26.2"
    log "========================================="
    
    # Verifica se o diretório de backup existe
    if [ ! -d "$BACKUP_ROOT" ]; then
        log "Criando diretório de backup: $BACKUP_ROOT"
        mkdir -p "$BACKUP_ROOT" || {
            log_error "Falha ao criar diretório de backup"
            exit 1
        }
    fi
    
    # Cria o diretório de backup desta execução
    mkdir -p "${BACKUP_DIR}" || {
        log_error "Falha ao criar diretório de backup"
        exit 1
    }
    
    # Verifica se os containers estão rodando
    log "Verificando containers..."
    check_container gitea || log_warning "Container Gitea não está rodando. O backup pode estar inconsistente."
    
    # Mostra a estrutura atual
    log "Estrutura atual do Gitea:"
    if [ -d "${VOLUME_ROOT}/gitea_data" ]; then
        ls -la "${VOLUME_ROOT}/gitea_data" 2>/dev/null | head -20 | while read line; do
            log "  $line"
        done
    fi
    
    # Executa os backups
    local has_error=0
    
    # Backup do banco de dados
    backup_database || has_error=1
    
    # Backup da configuração
    backup_config || has_error=1
    
    # Backup dos repositórios (corrigido para Gitea 1.26.2)
    backup_repositories || has_error=1
    
    # Backup do diretório git completo
    backup_git_data || has_error=1
    
    # Backup dos dados adicionais
    backup_gitea_data || has_error=1
    
    # Backup do runner
    backup_runner || has_error=1
    
    # Backup do registry
    #backup_registry || has_error=1
    
    # Dump das variáveis de ambiente
    backup_env
    
    # Cria o relatório
    create_report
    
    # Verifica integridade
    verify_backup || has_error=1
    
    # Limpa backups antigos
    cleanup_old_backups
    
    # Sumário final
    log "========================================="
    if [ $has_error -eq 0 ]; then
        log_success "BACKUP CONCLUÍDO COM SUCESSO!"
    else
        log_warning "BACKUP CONCLUÍDO COM ALGUNS AVISOS/ERROS"
    fi
    log "Diretório do backup: ${BACKUP_DIR}"
    log "Tamanho total: $(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)"
    log "Log disponível em: ${LOG_FILE}"
    log "========================================="
    
    # Compacta tudo em um único arquivo se solicitado
    if [ "${COMPRESS_BACKUP:-false}" = "true" ]; then
        log "Compactando backup completo..."
        local final_backup="${BACKUP_ROOT}/gitea_backup_${BACKUP_DATE}.tar.gz"
        tar -czf "$final_backup" -C "$BACKUP_ROOT" "gitea_backup_${BACKUP_DATE}" 2>/dev/null
        if [ -f "$final_backup" ]; then
            local size=$(du -h "$final_backup" | cut -f1)
            log_success "Backup compactado criado: $final_backup (tamanho: $size)"
            # Opcional: remover o diretório após compactar
            # rm -rf "${BACKUP_DIR}"
        fi
    fi
    
    exit $has_error
}

# Executa o script
main "$@"