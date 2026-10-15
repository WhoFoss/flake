#!/usr/bin/env bash

######################################################################
#---------------------------- VARIÁVEIS -----------------------------#
######################################################################

ambiente=""
config_file=""
socks_host="127.0.0.1"
socks_porta="9050"
porta_ctrl="9051"
tempo_limite=60
tor_pid=""
tor_log=""
datadir=""
dormir_pid=""
intervalo=0
tor_cookie=""

######################################################################
#------------------------------ CORES -------------------------------#
######################################################################

if [ -n "${TERM:-}" ] && command -v tput >/dev/null 2>&1; then
    verde=$(tput setaf 2)
    vermelho=$(tput setaf 1)
    amarelo=$(tput setaf 3)
    branco=$(tput setaf 7)
    negrito=$(tput bold)
    sublinhado=$(tput smul)
    reset=$(tput sgr0)
    cursor_off=$(tput civis)
    cursor_on=$(tput cnorm)
    destaque="$(tput setab 7)$(tput setaf 0)"
else
    verde=""; vermelho=""; amarelo=""; branco=""; negrito=""
    sublinhado=""; reset=""; cursor_off=""; cursor_on=""; destaque=""
fi

######################################################################
#---------------------------- MENSAGENS -----------------------------#
######################################################################

sucesso() { printf '%s%s%s\n' "$verde" "$1" "$reset"; }
info()    { printf '%s%s%s\n' "$branco" "$1" "$reset"; }
aviso()   { printf '%s%s%s\n' "$amarelo" "$1" "$reset"; }

erro() {
    printf '%s%s%s\n' "${negrito}${vermelho}" "$1" "$reset" >&2
    exit 1
}

uso() {
    printf '%sUso:%s ./flake.sh %sopção%s\n\n' "$negrito" "$reset" "$sublinhado" "$reset"
    printf ' %s-c%s Configura o proxychains para usar o Tor (socks5 %s:%s)\n' "$negrito" "$reset" "$socks_host" "$socks_porta"
    printf ' %s-t%s Inicia/acompanha o Tor em segundo plano\n' "$negrito" "$reset"
    printf ' %s-r [s]%s Como o -t, trocando de IP a cada s segundos (padrão 60, mínimo 10)\n' "$negrito" "$reset"
    printf ' %s-h%s Mostra esta ajuda\n' "$negrito" "$reset"
}

######################################################################
#--------------------------- AMBIENTE -------------------------------#
######################################################################

detectar_ambiente() {
    if [ -d /data/data/com.termux ]; then
        ambiente="local"
    elif command -v apt-get >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
        ambiente="sistema"
    else
        erro "Ambiente não suportado (nem Termux, nem Debian/Ubuntu/Mint)."
    fi
}

######################################################################
#--------------------------- DEPENDÊNCIAS ---------------------------#
######################################################################

verificar_dependencias() {
    local deps_base="curl od cut sed grep tail mktemp"
    local deps_extra=""
    local faltando=""

    case "$ambiente" in
        local)   deps_extra="tor proxychains4" ;;
        sistema) deps_extra="tor proxychains4 systemctl" ;;
    esac

    local dep
    for dep in $deps_base $deps_extra; do
        command -v "$dep" >/dev/null 2>&1 || faltando="${faltando:+$faltando }$dep"
    done

    [ -z "$faltando" ] && return 0

    printf '%s%s%s\n' "${negrito}${vermelho}" "Dependências ausentes: ${faltando}" "$reset" >&2
    case "$ambiente" in
        local)   info "Instale com: pkg install tor proxychains-ng curl coreutils" >&2 ;;
        sistema) info "Instale com: sudo apt install tor proxychains4 curl coreutils" >&2 ;;
    esac
    exit 1
}

######################################################################
#--------------------- CONTROLE / AMBIENTE --------------------------#
######################################################################

# Garante que o ControlPort responde (edita torrc se necessário)
preparar_controle() {
    local torrc="/etc/tor/torrc"
    [ -f "$torrc" ] || erro "Arquivo $torrc não encontrado."

    local precisa=0
    grep -qE '^ControlPort[[:space:]]+'"$porta_ctrl" "$torrc" 2>/dev/null || precisa=1
    grep -qE '^CookieAuthentication[[:space:]]+1'     "$torrc" 2>/dev/null || precisa=1

    if [ "$precisa" -eq 1 ]; then
        {
            printf '\n# Adicionado por flake.sh\n'
            grep -qE '^ControlPort[[:space:]]+'"$porta_ctrl" "$torrc" 2>/dev/null \
                || printf 'ControlPort %s\n' "$porta_ctrl"
            grep -qE '^CookieAuthentication[[:space:]]+1' "$torrc" 2>/dev/null \
                || printf 'CookieAuthentication 1\n'
        } | sudo tee -a "$torrc" >/dev/null || erro "Falha ao escrever em $torrc."

        sudo systemctl restart tor 2>/dev/null \
            || erro "Falha ao reiniciar o tor via systemctl."

        aviso "[+] torrc atualizado e tor reiniciado."
    fi

    local i=0
    while [ "$i" -lt 15 ]; do
        if (exec 3<>/dev/tcp/127.0.0.1/"$porta_ctrl") 2>/dev/null; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    erro "ControlPort $porta_ctrl não respondeu."
}

# Espera a porta SOCKS responder
esperar_socks() {
    local i=0
    while [ "$i" -lt 15 ]; do
        if (exec 3<>/dev/tcp/127.0.0.1/"$socks_porta") 2>/dev/null; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    erro "SOCKS em $socks_host:$socks_porta não respondeu."
}

# Deixa o ambiente pronto pro modo -t/-r
preparar_ambiente() {
    systemctl is-active --quiet tor || {
        info "Iniciando serviço tor..."
        sudo systemctl start tor || erro "Falha ao iniciar o tor."
    }
    preparar_controle
    esperar_socks
    sucesso "Tor pronto (SOCKS ${socks_host}:${socks_porta}, controle ${porta_ctrl})."
}

# Inicia um tor local em background (usado quando não há tor do sistema)
iniciar_tor_local() {
    local opcoes=()
    tor_log=$(mktemp)

    if [ "$intervalo" -gt 0 ]; then
        datadir=$(mktemp -d)
        opcoes=(--DataDirectory "$datadir" \
                --ControlPort "127.0.0.1:${porta_ctrl}" \
                --CookieAuthentication 1)
    fi

    tor ${opcoes[@]+"${opcoes[@]}"} > "$tor_log" 2>&1 &
    tor_pid=$!
    info "Iniciando conexão Tor..."
}

# Aguarda o bootstrap do tor local até 100%
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

######################################################################
#------------------------- PROXYCHAINS (-c) -------------------------#
######################################################################

detectar_config() {
    local candidato
    case "$ambiente" in
        local)
            for candidato in "${PREFIX:-}/etc/proxychains.conf" \
                             "${PREFIX:-}/etc/proxychains4.conf"; do
                [ -f "$candidato" ] && { config_file="$candidato"; return 0; }
            done
            ;;
        sistema)
            for candidato in /etc/proxychains4.conf /etc/proxychains.conf; do
                [ -f "$candidato" ] && { config_file="$candidato"; return 0; }
            done
            ;;
    esac
    erro "Arquivo de configuração do proxychains não encontrado."
}

verificar_permissao() {
    [ -w "$config_file" ] && return 0
    if [ "$ambiente" = "sistema" ]; then
        aviso "[+] Precisa de sudo para editar $config_file."
        return 0
    fi
    erro "Sem permissão de escrita em $config_file."
}

editar_config() {
    if [ -w "$config_file" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

aplicar_config() {
    editar_config sed -i 's/^strict_chain/#strict_chain/' "$config_file"
    sucesso "Strict chain desabilitado."

    editar_config sed -i 's/^#dynamic_chain[[:space:]]*$/dynamic_chain/' "$config_file"
    sucesso "Dynamic chain habilitado."

    editar_config sed -i 's/^#proxy_dns[[:space:]]*$/proxy_dns/' "$config_file"
    editar_config sed -i -E 's/^(proxy_dns_old|proxy_dns_daemon)/#\1/' "$config_file"
    if ! grep -Eq '^proxy_dns[[:space:]]*$' "$config_file"; then
        editar_config sed -i '/^\[ProxyList\]/i proxy_dns' "$config_file"
    fi
    sucesso "Proxy DNS habilitado (sem vazamento de DNS)."

    editar_config sed -i -E 's/^(socks4[[:space:]]+127\.0\.0\.1[[:space:]]+(9050|9095))/#\1/' "$config_file"
    if ! grep -Eq "^socks5[[:space:]]+${socks_host//./\\.}[[:space:]]+${socks_porta}" "$config_file"; then
        if [ -n "$(tail -c1 "$config_file")" ]; then
            printf '\n' | editar_config tee -a "$config_file" >/dev/null
        fi
        printf 'socks5 %s %s\n' "$socks_host" "$socks_porta" \
            | editar_config tee -a "$config_file" >/dev/null
    fi
    sucesso "Proxy socks5 configurado em ${socks_host}:${socks_porta}."
}

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

modo_config() {
    detectar_config
    info "Configurando: ${sublinhado}${config_file}${reset}${branco}"
    verificar_permissao
    aplicar_config
    verificar_resultado
    printf '%s%s%s\n' "${negrito}${verde}" "Configuração do proxychains concluída com sucesso!" "$reset"
    info "Teste: proxychains4 curl https://check.torproject.org/api/ip"
}

######################################################################
#----------------------------- COOKIE -------------------------------#
######################################################################

# Lê o cookie de controle do Tor (uma vez) e cacheia em $tor_cookie
carregar_cookie() {
    case "$ambiente" in
        local)
            tor_cookie=$(od -An -v -tx1 "$datadir/control_auth_cookie" 2>/dev/null | tr -d ' \n')
            ;;
        sistema)
            tor_cookie=$(sudo od -An -v -tx1 /var/run/tor/control.authcookie 2>/dev/null | tr -d ' \n')
            ;;
    esac
    [ -n "$tor_cookie" ] || erro "Não consegui ler o cookie de controle do Tor."
}

######################################################################
#----------------------------- TOR ----------------------------------#
######################################################################

limpar() {
    trap - EXIT INT TERM
    printf '%s' "$cursor_on"

    if [ -n "$dormir_pid" ]; then
        kill "$dormir_pid" 2>/dev/null
    fi

    # Só mata o tor se fomos nós que o iniciamos
    if [ "$ambiente" = "local" ] && [ -n "$tor_pid" ] && kill -0 "$tor_pid" 2>/dev/null; then
        info "Interrompendo a conexão Tor..."
        kill "$tor_pid" 2>/dev/null
        wait "$tor_pid" 2>/dev/null
    fi

    [ -n "$tor_log" ] && rm -f "$tor_log"
    [ -n "$datadir" ] && rm -rf "$datadir"
}

######################################################################
#-------------------------- TROCA DE IP -----------------------------#
######################################################################

trocar_ip() {
    [ -n "$tor_cookie" ] || return 1

    exec 3<>"/dev/tcp/127.0.0.1/${porta_ctrl}" 2>/dev/null || return 1
    printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$tor_cookie" >&3

    local ok=0 linha
    while IFS= read -r -t 5 linha <&3; do
        case "$linha" in
            "250 OK"*) ok=$((ok + 1)) ;;
            "250 closing"*|"5"*) break ;;
        esac
    done
    exec 3>&-
    [ "$ok" -ge 2 ] || return 1

    sleep 1
    local ip
    ip=$(curl -s --socks5-hostname "${socks_host}:${socks_porta}" \
         https://check.torproject.org/api/ip | grep -oE '"IP":"[^"]+"' | cut -d'"' -f4)
    printf 'Novo IP Tor: %s\n' "${ip:-indisponível}"
}

loop_troca() {
    sleep 3s; clear
    printf '%s%s%s\n' "${negrito}${branco}" "Troca de IP a cada ${intervalo}s." "$reset"

    while true; do
        if [ "$ambiente" = "local" ] && ! kill -0 "$tor_pid" 2>/dev/null; then
            break
        fi

        sleep "$intervalo" & dormir_pid=$!
        wait "$dormir_pid" 2>/dev/null
        [ "$ambiente" = "local" ] && ! kill -0 "$tor_pid" 2>/dev/null && break

        trocar_ip || info "Troca falhou ao falar com o Tor."
    done
}

validar_intervalo() {
    case "$1" in
        ""|*[!0-9]*) erro "Intervalo inválido: $1 (use um número de segundos)." ;;
    esac
    [ "$1" -ge 10 ] || erro "Intervalo mínimo é 10 segundos."
}

######################################################################
#----------------------------- MODOS --------------------------------#
######################################################################

modo_tor() {
    intervalo="${1:-0}"
    clear
    trap limpar EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '%s' "$cursor_off"

    if [ "$ambiente" = "local" ]; then
        iniciar_tor_local
        aguardar_conexao
    else
        preparar_ambiente
    fi

    carregar_cookie

    sucesso "Tor em execução. Pressione ${negrito}Ctrl+C${reset}${verde} para encerrar."
    printf '\n'
    info "Teste em outro terminal:"
    printf '%sproxychains4 curl -s https://check.torproject.org/api/ip%s\n' "$destaque" "$reset"

    if [ "$intervalo" -gt 0 ]; then
        loop_troca
    else
        if [ "$ambiente" = "local" ]; then
            wait "$tor_pid"
        else
            info "Aguardando Ctrl+C..."
            while true; do sleep 3600; done
        fi
    fi

    info "Encerrado."
}

######################################################################
#---------------------------- PRINCIPAL -----------------------------#
######################################################################

principal() {
    detectar_ambiente

    case "${1:-}" in
        -c)
            verificar_dependencias
            modo_config
            ;;
        -t)
            verificar_dependencias
            modo_tor 0
            ;;
        -r)
            validar_intervalo "${2:-60}"
            verificar_dependencias
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
