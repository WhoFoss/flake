#!/usr/bin/env bash

set -u

######################################################################
#---------------------------- VARIÁVEIS -----------------------------#
######################################################################

config_file=""
socks_host="127.0.0.1"
socks_porta="9050"
tempo_limite=60
tor_pid=""
tor_log=""
datadir=""
dormir_pid=""
intervalo=0
porta_ctrl="9051"

######################################################################
#------------------------------ CORES -------------------------------#
######################################################################

if [ -n "${TERM:-}" ] && command -v tput >/dev/null 2>&1; then
    verde=$(tput setaf 2)
    vermelho=$(tput setaf 1)
    branco=$(tput setaf 7)
    negrito=$(tput bold)
    sublinhado=$(tput smul)
    reverso=$(tput rev)
    reset=$(tput sgr0)
    cursor_off=$(tput civis)
    cursor_on=$(tput cnorm)
    destaque="$(tput setab 7)$(tput setaf 0)"
else
    verde=""
    vermelho=""
    branco=""
    negrito=""
    sublinhado=""
    reverso=""
    reset=""
    cursor_off=""
    cursor_on=""
    destaque=""
fi

######################################################################
#---------------------------- MENSAGENS -----------------------------#
######################################################################

# Exibe uma mensagem de sucesso em verde
sucesso() {
    printf '%s%s%s\n' "$verde" "$1" "$reset"
}

# Exibe uma mensagem informativa em branco
info() {
    printf '%s%s%s\n' "$branco" "$1" "$reset"
}

# Exibe uma mensagem de erro em vermelho e encerra o script
erro() {
    printf '%s%s%s\n' "${negrito}${vermelho}" "$1" "$reset" >&2
    exit 1
}

# Exibe como o script deve ser usado
uso() {
    printf '%sUso:%s ./flake.sh %sopção%s\n\n' "$negrito" "$reset" "$sublinhado" "$reset"
    printf ' %s-c%s Configura o proxychains para usar o Tor (socks5 %s:%s)\n' "$negrito" "$reset" "$socks_host" "$socks_porta"
    printf ' %s-t%s Inicia o Tor em segundo plano e acompanha a conexão\n' "$negrito" "$reset"
    printf ' %s-r [s]%s Como o -t, trocando de IP a cada s segundos (padrão 60, mínimo 10)\n' "$negrito" "$reset"
    printf ' %s-h%s Mostra esta ajuda\n' "$negrito" "$reset"
}

######################################################################
#--------------------------- DEPENDÊNCIAS ---------------------------#
######################################################################

# Verifica se as dependências recebidas como argumento estão instaladas
verificar_dependencias() {
    local dep faltando=""
    for dep in "$@"; do
        command -v "$dep" >/dev/null 2>&1 || faltando="${faltando:+$faltando }$dep"
    done
    [ -z "$faltando" ] && return 0

    printf '%s%s%s\n' "${negrito}${vermelho}" "Dependências ausentes: ${faltando}" "$reset" >&2
    if [ -d /data/data/com.termux ]; then
        info "Instale com: pkg install tor proxychains-ng curl coreutils" >&2
    else
        info "Instale com: sudo apt install tor proxychains4 curl coreutils" >&2
    fi
    exit 1
}

######################################################################
#------------------------- PROXYCHAINS (-c) -------------------------#
######################################################################

# Localiza o arquivo de configuração do proxychains (Termux ou Linux)
detectar_config() {
    local candidato
    for candidato in "${PREFIX:-}/etc/proxychains.conf" /etc/proxychains4.conf /etc/proxychains.conf; do
        if [ -f "$candidato" ]; then
            config_file="$candidato"
            return 0
        fi
    done
    erro "Arquivo de configuração do proxychains não encontrado."
}

# Garante permissão de escrita no arquivo (fora do Termux exige sudo)
verificar_permissao() {
    [ -w "$config_file" ] || erro "Sem permissão de escrita em $config_file. Execute com sudo."
}

# Aplica as alterações no arquivo de configuração
aplicar_config() {
    sed -i 's/^strict_chain/#strict_chain/' "$config_file"
    sucesso "Strict chain desabilitado."

    sed -i 's/^#dynamic_chain[[:space:]]*$/dynamic_chain/' "$config_file"
    sucesso "Dynamic chain habilitado."

    sed -i 's/^#proxy_dns[[:space:]]*$/proxy_dns/' "$config_file"
    sed -i -E 's/^(proxy_dns_old|proxy_dns_daemon)/#\1/' "$config_file"
    if ! grep -Eq '^proxy_dns[[:space:]]*$' "$config_file"; then
        sed -i '/^\[ProxyList\]/i proxy_dns' "$config_file"
    fi
    sucesso "Proxy DNS habilitado (sem vazamento de DNS)."

    sed -i -E 's/^(socks4[[:space:]]+127\.0\.0\.1[[:space:]]+(9050|9095))/#\1/' "$config_file"
    if ! grep -Eq "^socks5[[:space:]]+${socks_host//./\\.}[[:space:]]+${socks_porta}" "$config_file"; then
        if [ -n "$(tail -c1 "$config_file")" ]; then
            printf '\n' >> "$config_file"
        fi
        printf 'socks5 %s %s\n' "$socks_host" "$socks_porta" >> "$config_file"
    fi
    sucesso "Proxy socks5 configurado em ${socks_host}:${socks_porta}."
}

# Confere se todas as alterações ficaram ativas no arquivo
verificar_resultado() {
    grep -q '^dynamic_chain' "$config_file" || erro "dynamic_chain não ficou ativo."
    if grep -q '^strict_chain' "$config_file"; then
        erro "strict_chain continua ativo."
    fi
    grep -Eq '^proxy_dns[[:space:]]*$' "$config_file" || erro "proxy_dns não ficou ativo."
    if grep -Eq '^(proxy_dns_old|proxy_dns_daemon)' "$config_file"; then
        erro "proxy_dns_old/daemon continua ativo."
    fi
    if grep -Eq '^socks4[[:space:]]+127\.0\.0\.1' "$config_file"; then
        erro "socks4 local continua ativo."
    fi
    grep -Eq "^socks5[[:space:]]+${socks_host//./\\.}[[:space:]]+${socks_porta}" "$config_file" \
        || erro "Linha socks5 não encontrada."
}

# Executa a configuração completa do proxychains
modo_config() {
    detectar_config
    info "Configurando: ${sublinhado}${config_file}${reset}${branco}"
    verificar_permissao
    aplicar_config
    verificar_resultado
    printf '%s%s%s\n' "${negrito}${verde}" "Configuração do proxychains concluída com sucesso!" "$reset"
    info "Teste: proxychains4 curl ifconfig.me"
}

######################################################################
#-------------------------- TOR (-t / -r) ---------------------------#
######################################################################

# Encerra o Tor, apaga os temporários e restaura o cursor do terminal
limpar() {
    trap - EXIT INT TERM
    printf '%s' "$cursor_on"

    if [ -n "$dormir_pid" ]; then
        kill "$dormir_pid" 2>/dev/null
    fi

    if [ -n "$tor_pid" ] && kill -0 "$tor_pid" 2>/dev/null; then
        info "Interrompendo a conexão Tor..."
        kill "$tor_pid" 2>/dev/null
        wait "$tor_pid" 2>/dev/null
    fi

    if [ -n "$tor_log" ]; then
        rm -f "$tor_log"
    fi

    if [ -n "$datadir" ]; then
        rm -rf "$datadir"
    fi
}

# Verifica se uma porta local já está em uso por outro processo
porta_em_uso() {
    ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null
}

# Avisa e encerra se as portas que o Tor precisa já estiverem ocupadas
verificar_portas() {
    if porta_em_uso "$socks_porta"; then
        erro "A porta ${socks_porta} já está em uso (provável Tor do sistema). Pare-o antes: sudo systemctl stop tor"
    fi
    if [ "$intervalo" -gt 0 ] && porta_em_uso "$porta_ctrl"; then
        erro "A porta de controle ${porta_ctrl} já está em uso. Pare o outro Tor antes."
    fi
}

# Inicia o Tor em segundo plano (com porta de controle no modo -r)
iniciar_tor() {
    local opcoes=()
    tor_log=$(mktemp)

    if [ "$intervalo" -gt 0 ]; then
        datadir=$(mktemp -d)
        opcoes=(--DataDirectory "$datadir" --ControlPort "127.0.0.1:${porta_ctrl}" --CookieAuthentication 1)
    fi

    tor ${opcoes[@]+"${opcoes[@]}"} > "$tor_log" 2>&1 &
    tor_pid=$!
    info "Iniciando conexão Tor..."
}

# Acompanha o bootstrap do Tor até 100% ou até estourar o tempo limite
aguardar_conexao() {
    local decorrido=0 progresso="" anterior=""
    while [ "$decorrido" -lt "$tempo_limite" ]; do
        if ! kill -0 "$tor_pid" 2>/dev/null; then
            tail -n 5 "$tor_log" >&2
            erro "O Tor encerrou inesperadamente."
        fi

        progresso=$(grep -oE 'Bootstrapped [0-9]{1,3}%' "$tor_log" | tail -n1 | grep -oE '[0-9]{1,3}')
        if [ "$progresso" = "100" ]; then
            sucesso "Conexão Tor estabelecida (100%)"
            return 0
        fi

        if [ -n "$progresso" ] && [ "$progresso" != "$anterior" ]; then
            info "Progresso: ${progresso}%"
            anterior="$progresso"
        fi

        sleep 1
        decorrido=$((decorrido + 1))
    done

    tail -n 5 "$tor_log" >&2
    erro "Tempo limite de ${tempo_limite}s excedido sem conectar ao Tor."
}

# Consulta o IP atual de saída do Tor, tentando de novo em caso de falha
consultar_ip() {
    local ip="" tentativa
    for tentativa in 1 2 3; do
        sleep 2
        ip=$(curl -s --max-time 15 --socks5-hostname "${socks_host}:${socks_porta}" \
             https://check.torproject.org/api/ip | grep -oE '"IP":"[^"]+"' | cut -d'"' -f4)
        [ -n "$ip" ] && break
    done
    printf '%s' "$ip"
}

# Pede circuitos novos ao Tor (NEWNYM) e mostra o novo IP
trocar_ip() {
    local cookie ip ok=0 linha
    cookie=$(od -An -v -tx1 "$datadir/control_auth_cookie" 2>/dev/null | tr -d ' \n')
    [ -n "$cookie" ] || return 1

    { exec 3<>"/dev/tcp/127.0.0.1/${porta_ctrl}"; } 2>/dev/null || return 1
    printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$cookie" >&3

    while IFS= read -r -t 5 linha <&3; do
        case "$linha" in
            "250 OK"*) ok=$((ok + 1)) ;;
            "250 closing"*|"5"*) break ;;
        esac
    done
    exec 3>&-
    [ "$ok" -ge 2 ] || return 1

    ip=$(consultar_ip)
    printf 'Novo IP Tor: %s\n' "${ip:-indisponível}"
}

# Mostra a dica de teste do proxychains
mostrar_dica() {
    info "Teste em outro terminal:"
    printf '%sproxychains4 curl -s https://check.torproject.org/api/ip%s\n' "$destaque" "$reset"
}

# Limpa a tela e troca de IP a cada intervalo até o Tor ser encerrado
loop_troca() {
    local n=0
    sleep 3; clear
    printf '%s%s%s\n' "${negrito}${branco}" "Troca de IP a cada ${intervalo}s. Ctrl+C para encerrar." "$reset"
    mostrar_dica
    printf '\n'

    while kill -0 "$tor_pid" 2>/dev/null; do
        sleep "$intervalo" & dormir_pid=$!
        wait "$dormir_pid" 2>/dev/null
        kill -0 "$tor_pid" 2>/dev/null || break

        n=$((n + 1))
        trocar_ip || info "Troca ${n} às $(date +%H:%M:%S): falhou ao falar com o Tor."
    done
}

# Valida o intervalo de troca de IP (inteiro, mínimo 10 segundos)
validar_intervalo() {
    case "$1" in
        ""|*[!0-9]*) erro "Intervalo inválido: $1 (use um número de segundos)." ;;
    esac
    [ "$1" -ge 10 ] || erro "Intervalo mínimo é 10 segundos (limite do Tor para trocar de circuito)."
}

# Inicia o Tor, aguarda a conexão e mantém o script em execução
modo_tor() {
    intervalo="${1:-0}"
    clear
    verificar_portas
    trap limpar EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '%s' "$cursor_off"

    iniciar_tor
    aguardar_conexao

    sucesso "Tor em execução. Pressione ${negrito}Ctrl+C${reset}${verde} para encerrar."
    printf '\n'

    if [ "$intervalo" -gt 0 ]; then
        loop_troca
    else
        mostrar_dica
        wait "$tor_pid"
    fi

    info "O Tor foi encerrado."
}

######################################################################
#---------------------------- PRINCIPAL -----------------------------#
######################################################################

# Interpreta a opção recebida e chama o modo correspondente
principal() {
    case "${1:-}" in
        -c)
            verificar_dependencias proxychains4 sed grep tail
            modo_config
            ;;
        -t)
            verificar_dependencias tor mktemp grep tail
            modo_tor 0
            ;;
        -r)
            validar_intervalo "${2:-60}"
            verificar_dependencias tor curl od tr cut mktemp grep tail
            modo_tor "${2:-60}"
            ;;
        -h|"")
            uso
            ;;
        *)
            printf '%sOpção inválida: %s%s\n\n' "$vermelho" "$1" "$reset" >&2
            uso >&2
            exit 1
            ;;
    esac
}

principal "$@"
