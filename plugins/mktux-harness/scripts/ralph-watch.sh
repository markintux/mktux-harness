#!/usr/bin/env bash
#
# ralph-watch.sh
#
# Painel ao vivo do run do ralph.sh. So LE: o ralph e a unica fonte de verdade.
# Nada aqui escreve no repositorio, nada aqui influencia o run — fechar o painel
# no meio nao muda nada no ralph.
#
# Uso:
#   ralph-watch [opcoes] [caminho-do-repo]
#
# Opcoes:
#   --once            desenha um quadro e sai (bom para pipe/CI)
#   --interval N      segundos entre quadros (default: 1)
#   --embedded        chamado pelo `ralph.sh --dashboard` (rodape e saida diferentes)
#   --no-color        sem ANSI
#   --color           forca ANSI mesmo sem TTY
#   --tail N          linhas do log da engine no box do rodape (default: 6, 0 desliga)
#
# Teclas:
#   ↑/↓ ou k/j        rola a tabela
#   PgUp/PgDn, b/space
#   Home/End ou g/G
#   f                 segue a fase corrente (default: ligado)
#   t                 liga/desliga o box com o log da engine
#   q                 sai (nao mexe no run)
#
# Layout: cabecalho de identificacao, dois boxes (PROGRESSO e TRABALHO ATUAL),
# a tabela de fases/tasks com bordas — que rola dentro da altura do terminal — e
# o box do log da engine no rodape.
#
# Fonte: .phases/state/run.tsv, publicado pelo ralph a cada transicao (com ou
# sem --dashboard). Contrato do arquivo documentado no cabecalho do ralph.sh.
# Tokens: .harness/tokens.jsonl (hook log-tokens.sh), filtrado pelo inicio do run.
#
# bash 3.2 (o do macOS): sem array associativo, sem mapfile, sem read -t fracionado.

set -uo pipefail

# ${#s} e ${s:0:n} so contam CARACTERES em locale UTF-8; em C eles contam bytes
# e toda a tabela desalinha (os glifos ocupam 3 bytes).
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*utf8*) : ;;
  *) export LC_ALL=en_US.UTF-8 ;;
esac

REPO="."
ONCE=0
EMBEDDED=0
INTERVAL=1
TAIL_LINES=6
COLOR="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)        ONCE=1; shift ;;
    --embedded)    EMBEDDED=1; shift ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    --interval=*)  INTERVAL="${1#*=}"; shift ;;
    --tail)        TAIL_LINES="$2"; shift 2 ;;
    --tail=*)      TAIL_LINES="${1#*=}"; shift ;;
    --no-color)    COLOR="off"; shift ;;
    --color)       COLOR="on"; shift ;;
    -h|--help)     sed -n '2,38p' "$0"; exit 0 ;;
    *)             REPO="$1"; shift ;;
  esac
done

[[ "$INTERVAL" =~ ^[0-9]+$ ]] || INTERVAL=1
[ "$INTERVAL" -lt 1 ] && INTERVAL=1
[[ "$TAIL_LINES" =~ ^[0-9]+$ ]] || TAIL_LINES=6

REPO="$(cd "$REPO" 2> /dev/null && pwd)" || { echo "repo nao encontrado" >&2; exit 1; }
STATE_FILE="$REPO/.phases/state/run.tsv"
TOKENS_FILE="$REPO/.harness/tokens.jsonl"

# Sem terminal nao ha o que animar: um quadro e pronto.
if [ ! -t 1 ]; then
  ONCE=1
fi

USE_COLOR=0
case "$COLOR" in
  on)  USE_COLOR=1 ;;
  off) USE_COLOR=0 ;;
  *)   [ -t 1 ] && USE_COLOR=1 ;;
esac

if [ "$USE_COLOR" -eq 1 ]; then
  C_RESET=$'\033[0m';  C_DIM=$'\033[2m';   C_BOLD=$'\033[1m'
  C_CYAN=$'\033[38;5;81m';  C_GREEN=$'\033[38;5;77m'; C_YELLOW=$'\033[38;5;221m'
  C_RED=$'\033[38;5;203m';  C_GREY=$'\033[38;5;245m'; C_WHITE=$'\033[38;5;255m'
  C_HILITE=$'\033[48;5;53m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GREY=""; C_WHITE=""
  C_HILITE=""
fi

# ---------------------------------------------------------------------------
# Estado lido do run.tsv
# ---------------------------------------------------------------------------

M_ENGINE=""; M_MODEL=""; M_EFFORT=""; M_VERIFY=""; M_MAXCYCLES=""
M_TESTCMD=""; M_INPUT=""; M_BRANCH=""; M_PID=""; M_TOTAL=0
M_START=0; M_START_ISO=""; M_UPDATED=0; M_STATUS=""; M_RUNLOG=""

P_N=0; T_N=0
P_SEQ=(); P_NUM=(); P_STATUS=(); P_CYCLE=(); P_START=(); P_DUR=(); P_GATES=(); P_TITLE=()
T_SEQ=(); T_IDX=(); T_STATUS=(); T_TEXT=()
W_ACTIVE=0; W_UNTIL=0; W_COUNT=0; W_MAX=0
L_KIND=""; L_PATH=""

CUR_SEQ=0

read_state() {
  P_N=0; T_N=0
  P_SEQ=(); P_NUM=(); P_STATUS=(); P_CYCLE=(); P_START=(); P_DUR=(); P_GATES=(); P_TITLE=()
  T_SEQ=(); T_IDX=(); T_STATUS=(); T_TEXT=()
  W_ACTIVE=0; W_UNTIL=0; W_COUNT=0; W_MAX=0
  L_KIND=""; L_PATH=""
  CUR_SEQ=0

  [ -f "$STATE_FILE" ] || return 1

  local kind a b c d e f g h
  while IFS=$'\t' read -r kind a b c d e f g h; do
    case "$kind" in
      META)
        case "$a" in
          engine)     M_ENGINE="$b" ;;
          model)      M_MODEL="$b" ;;
          effort)     M_EFFORT="$b" ;;
          verify)     M_VERIFY="$b" ;;
          max_cycles) M_MAXCYCLES="$b" ;;
          test_cmd)   M_TESTCMD="$b" ;;
          input)      M_INPUT="$b" ;;
          branch)     M_BRANCH="$b" ;;
          pid)        M_PID="$b" ;;
          total)      M_TOTAL="$b" ;;
          start)      M_START="$b" ;;
          start_iso)  M_START_ISO="$b" ;;
          updated)    M_UPDATED="$b" ;;
          status)     M_STATUS="$b" ;;
          run_log)    M_RUNLOG="$b" ;;
        esac
        ;;
      PHASE)
        P_N=$((P_N + 1))
        P_SEQ[$P_N]="$a"; P_NUM[$P_N]="$b"; P_STATUS[$P_N]="$c"; P_CYCLE[$P_N]="$d"
        P_START[$P_N]="$e"; P_DUR[$P_N]="$f"; P_GATES[$P_N]="$g"; P_TITLE[$P_N]="$h"
        [ "$c" = "running" ] && CUR_SEQ="$a"
        ;;
      TASK)
        T_N=$((T_N + 1))
        T_SEQ[$T_N]="$a"; T_IDX[$T_N]="$b"; T_STATUS[$T_N]="$c"; T_TEXT[$T_N]="$d"
        ;;
      WAIT)
        W_ACTIVE="$a"; W_UNTIL="$b"; W_COUNT="$c"; W_MAX="$d"
        ;;
      LOG)
        L_KIND="$a"; L_PATH="$b"
        ;;
    esac
  done < "$STATE_FILE"

  return 0
}

# ---------------------------------------------------------------------------
# Primitivas de desenho
#
# As funcoes *_v escrevem na variavel nomeada em $1 em vez de na saida: cada
# `$(pad ...)` custa um fork, e a tabela inteira e remontada a cada quadro E a
# cada tecla de rolagem. Toda variavel interna leva prefixo __ porque o destino
# vem do chamador — um `local out` aqui dentro sequestraria o `pad_v out ...`.
# ---------------------------------------------------------------------------

pad_v() { # <destino> <texto> <largura>
  local __s="$2" __w="$3" __n
  if [ "$__w" -lt 1 ]; then printf -v "$1" '%s' ''; return; fi
  __n=${#2}
  if [ "$__n" -gt "$__w" ]; then
    if [ "$__w" -gt 1 ]; then __s="${__s:0:__w-1}…"; else __s="${__s:0:__w}"; fi
    __n=$__w
  fi
  printf -v "$1" '%s%*s' "$__s" $((__w - __n)) ''
}

pad() {
  local REPLY_PAD
  pad_v REPLY_PAD "$1" "$2"
  printf '%s' "$REPLY_PAD"
}

# cell_v <destino> <colorido> <plain> <largura> — mede o texto SEM ANSI e
# completa a diferenca. Padear depois de colorir inflaria a coluna, porque o
# escape ANSI conta em ${#s}.
cell_v() {
  local __n=${#3}
  if [ "$__n" -gt "$4" ]; then pad_v "$1" "$3" "$4"; return; fi
  printf -v "$1" '%s%*s' "$2" $(($4 - __n)) ''
}

repeat_v() { # <destino> <char> <n>
  local __out="" __i
  for ((__i = 0; __i < $3; __i++)); do __out="${__out}$2"; done
  printf -v "$1" '%s' "$__out"
}

bar_v() { # <destino> <feito> <total> <largura>
  local __filled=0 __f __e
  [ "$3" -gt 0 ] && __filled=$(($2 * $4 / $3))
  [ "$__filled" -gt "$4" ] && __filled=$4
  repeat_v __f '█' "$__filled"
  repeat_v __e '░' $(($4 - __filled))
  printf -v "$1" '%s%s%s%s%s' "$C_GREEN" "$__f" "$C_GREY" "$__e" "$C_RESET"
}

pct_v() { # <destino> <n> <total>
  if [ "$3" -gt 0 ]; then printf -v "$1" '%d%%' $(($2 * 100 / $3))
  else printf -v "$1" '0%%'; fi
}

# Duracao longa (cabecalho): 1h 07m 45s
fmt_duration() {
  local t="${1:-0}" h m s
  [ "$t" -lt 0 ] && t=0
  h=$((t / 3600)); m=$(((t % 3600) / 60)); s=$((t % 60))
  if [ "$h" -gt 0 ]; then printf '%dh %02dm %02ds' "$h" "$m" "$s"
  elif [ "$m" -gt 0 ]; then printf '%dm %02ds' "$m" "$s"
  else printf '%ds' "$s"; fi
}

# Duracao compacta (coluna Tempo): 17m24s
fmt_dur() {
  local s="${1:-0}"
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60)); fi
}

human_num() {
  local n="${1:-0}"
  if [ "$n" -ge 1000000 ]; then
    printf '%d.%dM' $((n / 1000000)) $(((n % 1000000) / 100000))
  elif [ "$n" -ge 1000 ]; then
    printf '%dK' $((n / 1000))
  else
    printf '%d' "$n"
  fi
}

# ---------------------------------------------------------------------------
# Vocabulario -> rotulo
# ---------------------------------------------------------------------------

# status_pair_v <destino colorido> <destino plain> <status>
status_pair_v() {
  local __p __c
  case "$3" in
    done)     __p='✓ Concluída';   __c="${C_GREEN}${__p}${C_RESET}" ;;
    running)  __p='▶ Em execução';  __c="${C_YELLOW}${__p}${C_RESET}" ;;
    failed)   __p='✗ Falhou';      __c="${C_RED}${__p}${C_RESET}" ;;
    manual)   __p='◇ Manual';      __c="${C_YELLOW}${__p}${C_RESET}" ;;
    skipped)  __p='– Pulada';      __c="${C_GREY}${__p}${C_RESET}" ;;
    *)        __p='· Pendente';    __c="${C_GREY}${__p}${C_RESET}" ;;
  esac
  printf -v "$1" '%s' "$__c"
  printf -v "$2" '%s' "$__p"
}

run_status_pair_v() { # <destino colorido> <destino plain>
  local __p __c
  case "$M_STATUS" in
    running)
      if run_alive; then
        __p='▶ Em execução'; __c="${C_YELLOW}${__p}${C_RESET}"
      else
        __p="⚠ Órfão (pid ${M_PID} sumiu)"; __c="${C_RED}${__p}${C_RESET}"
      fi
      ;;
    done)   __p='✓ Concluído'; __c="${C_GREEN}${__p}${C_RESET}" ;;
    failed) __p='✗ Falhou';    __c="${C_RED}${__p}${C_RESET}" ;;
    *)      __p="· ${M_STATUS:-?}"; __c="${C_GREY}${__p}${C_RESET}" ;;
  esac
  [ "$W_ACTIVE" = "1" ] && { __p='⏸ Aguardando reset de limite'; __c="${C_YELLOW}${__p}${C_RESET}"; }
  printf -v "$1" '%s' "$__c"
  printf -v "$2" '%s' "$__p"
}

# gates_pair_v <destino colorido> <destino plain> <spec>
# spec: "0:pass:3,1:skip:0,2:run:0,3:pend:0"
gates_pair_v() {
  local __arr __i __g __st __c="" __p="" __mark __col
  IFS=',' read -r -a __arr <<< "${3:-}"
  for ((__i = 0; __i < ${#__arr[@]}; __i++)); do
    __g="${__arr[$__i]%%:*}"
    __st="${__arr[$__i]#*:}"; __st="${__st%%:*}"
    case "$__st" in
      pass) __mark='✓'; __col="$C_GREEN" ;;
      fail) __mark='✗'; __col="$C_RED" ;;
      run)  __mark='⋯'; __col="$C_YELLOW" ;;
      skip) __mark='⊘'; __col="$C_GREY" ;;
      *)    __mark='·'; __col="$C_GREY" ;;
    esac
    [ "$__i" -gt 0 ] && { __c="${__c} "; __p="${__p} "; }
    __c="${__c}${C_GREY}G${__g}${C_RESET} ${__col}${__mark}${C_RESET}"
    __p="${__p}G${__g} ${__mark}"
  done
  printf -v "$1" '%s' "$__c"
  printf -v "$2" '%s' "$__p"
}

# ---------------------------------------------------------------------------
# Contadores e leituras auxiliares
# ---------------------------------------------------------------------------

count_status() {
  local want="$1" i n=0
  for ((i = 1; i <= P_N; i++)); do
    [ "${P_STATUS[$i]}" = "$want" ] && n=$((n + 1))
  done
  printf '%d' "$n"
}

count_tasks() {
  local want="$1" i n=0
  for ((i = 1; i <= T_N; i++)); do
    [ "${T_STATUS[$i]}" = "$want" ] && n=$((n + 1))
  done
  printf '%d' "$n"
}

# Tokens gastos DESDE o inicio do run: o ts do tokens.jsonl e ISO-8601 em UTC,
# entao a comparacao de string basta — nada de converter data em bash.
tokens_summary() {
  if [ ! -f "$TOKENS_FILE" ] || [ -z "$M_START_ISO" ]; then
    printf '0 0 0 0'
    return
  fi
  tail -n 5000 "$TOKENS_FILE" 2> /dev/null | awk -v since="$M_START_ISO" '
    function num(k,   re, s) {
      re = "\"" k "\":[0-9]+"
      if (match($0, re)) { s = substr($0, RSTART, RLENGTH); sub(/^"[^"]*":/, "", s); return s + 0 }
      return 0
    }
    {
      ts = ""
      if (match($0, /"ts":"[^"]*"/)) { ts = substr($0, RSTART + 6, RLENGTH - 7) }
      if (ts == "" || ts < since) { next }
      n++
      i += num("input"); o += num("output")
      c += num("cache_read") + num("cache_creation")
    }
    END { printf "%d %d %d %d", n + 0, i + 0, o + 0, c + 0 }'
}

file_age() {
  local f="$1" mt
  [ -f "$f" ] || { printf '%d' -1; return; }
  mt=$(stat -f %m "$f" 2> /dev/null || stat -c %Y "$f" 2> /dev/null || echo 0)
  printf '%d' $(($(date +%s) - mt))
}

run_alive() {
  [ -n "$M_PID" ] || return 1
  kill -0 "$M_PID" 2> /dev/null
}

# Caminho absoluto do log ativo (o ralph publica relativo a raiz do repo).
active_log() {
  local src="$L_PATH"
  [ -z "$src" ] && src="$M_RUNLOG"
  [ -n "$src" ] || return 1
  if [ -f "$REPO/$src" ]; then printf '%s' "$REPO/$src"; return 0; fi
  if [ -f "$src" ]; then printf '%s' "$src"; return 0; fi
  return 1
}

# ---------------------------------------------------------------------------
# Boxes
# ---------------------------------------------------------------------------

# box_top_v <destino> <largura total> <titulo> — largura conta as duas quinas.
box_top_v() {
  local __w="$2" __t="$3" __inner __pre __l __r
  __inner=$((__w - 2))
  if [ "${#__t}" -gt $((__inner - 4)) ]; then __t="${__t:0:$((__inner - 5))}…"; fi
  __pre=$(((__inner - ${#__t} - 2) / 2))
  [ "$__pre" -lt 0 ] && __pre=0
  repeat_v __l '─' "$__pre"
  repeat_v __r '─' $((__inner - __pre - ${#__t} - 2))
  printf -v "$1" '%s┌%s %s %s┐%s' "$C_CYAN" "$__l" "$__t" "$__r" "$C_RESET"
}

box_bottom_v() { # <destino> <largura total>
  local __b
  repeat_v __b '─' $(($2 - 2))
  printf -v "$1" '%s└%s┘%s' "$C_CYAN" "$__b" "$C_RESET"
}

# box_line_v <destino> <colorido> <plain> <largura total>
box_line_v() {
  local __c
  cell_v __c "$2" "$3" $(($4 - 4))
  printf -v "$1" '%s│%s %s %s│%s' "$C_CYAN" "$C_RESET" "$__c" "$C_CYAN" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Montagem do quadro
# ---------------------------------------------------------------------------

TOP=(); TOP_N=0
BOT=(); BOT_N=0
ROW=(); ROW_N=0; ROW_HL=(); ROW_SEQ=()
PH_ROW_A=(); PH_ROW_B=()      # primeira/ultima linha de cada fase, por seq
RUN_ROW=0

add_top() { TOP_N=$((TOP_N + 1)); TOP[$TOP_N]="$1"; }
add_bot() { BOT_N=$((BOT_N + 1)); BOT[$BOT_N]="$1"; }
add_row() { ROW_N=$((ROW_N + 1)); ROW[$ROW_N]="$1"; ROW_HL[$ROW_N]="$2"; ROW_SEQ[$ROW_N]="$3"; }

SCROLL=0
FOLLOW=1
TAIL_ON=1

# Colunas fixas: 14 cabe "▶ Em execução", 19 cabe "G0 ✓ G1 ✓ G2 ✓ G3 ✓" inteiro,
# 9 cabe o cabecalho "Tentativa". Encolher qualquer um corta informacao.
COL_ID=4; COL_STATUS=14; COL_TRY=9; COL_TIME=7; COL_GATES=19; COL_NAME=20

build_header() {
  local now elapsed col c1 c2 c3 st_c st_p line
  now=$(date +%s)
  elapsed=$((now - M_START))
  [ "$M_START" -eq 0 ] && elapsed=0
  [ "$M_STATUS" != "running" ] && [ "$M_UPDATED" -gt "$M_START" ] \
    && elapsed=$((M_UPDATED - M_START))

  add_top ""
  add_top "${C_BOLD}${C_CYAN}RALPH${C_RESET}"
  add_top ""

  col=$(((COLS - 4) / 3))
  [ "$col" -lt 18 ] && col=18

  local engine="${M_ENGINE:-?} · ${M_MODEL:-default}"
  [ -n "$M_EFFORT" ] && [ "$M_EFFORT" != "default" ] && engine="$engine · $M_EFFORT"

  run_status_pair_v st_c st_p
  pad_v c1 "$(basename "$REPO")" $((col - 10))
  pad_v c2 "$engine" $((col - 9))
  printf -v line '%sProjeto:%s %s  %sEngine:%s %s  %sStatus:%s %s' \
    "$C_CYAN" "$C_RESET" "$c1" "$C_CYAN" "$C_RESET" "$c2" "$C_CYAN" "$C_RESET" "$st_c"
  add_top "$line"

  pad_v c1 "$(fmt_duration "$elapsed")" $((col - 10))
  pad_v c2 "${M_BRANCH:-?}" $((col - 9))
  printf -v line '%sDuração:%s %s  %sBranch:%s %s  %sPID:%s %s' \
    "$C_CYAN" "$C_RESET" "$c1" "$C_CYAN" "$C_RESET" "$c2" "$C_CYAN" "$C_RESET" "${M_PID:-?}"
  add_top "$line"
  add_top ""
}

build_panels() {
  local lw rw i n
  lw=$(((COLS - 1) / 2))
  rw=$((COLS - lw - 1))

  local L=() LP=() R=() RP=() ln=0 rn=0
  local ph_done ph_total tk_done tk_total bw
  ph_done=$(($(count_status done) + $(count_status skipped)))
  ph_total=$P_N
  tk_done=$(count_tasks done)
  tk_total=$T_N

  bw=$((lw - 4 - 24))
  [ "$bw" -lt 8 ] && bw=8

  local n_ph n_tk p_ph p_tk b_ph b_tk blank tmp
  pad_v n_ph "$ph_done/$ph_total" 7
  pad_v n_tk "$tk_done/$tk_total" 7
  pct_v p_ph "$ph_done" "$ph_total"
  pct_v p_tk "$tk_done" "$tk_total"
  bar_v b_ph "$ph_done" "$ph_total" "$bw"
  bar_v b_tk "$tk_done" "$tk_total" "$bw"
  repeat_v blank ' ' "$bw"

  ln=$((ln + 1)); printf -v tmp 'Fases  %s  [%s]  %s' "$n_ph" "$b_ph" "$p_ph"; L[$ln]="$tmp"
  printf -v tmp 'Fases  %s  [%s]  %s' "$n_ph" "$blank" "$p_ph"; LP[$ln]="$tmp"
  ln=$((ln + 1)); printf -v tmp 'Tasks  %s  [%s]  %s' "$n_tk" "$b_tk" "$p_tk"; L[$ln]="$tmp"
  printf -v tmp 'Tasks  %s  [%s]  %s' "$n_tk" "$blank" "$p_tk"; LP[$ln]="$tmp"
  ln=$((ln + 1)); L[$ln]=""; LP[$ln]=""

  ln=$((ln + 1))
  printf -v tmp '%sTeste:%s  %s' "$C_CYAN" "$C_RESET" "${M_TESTCMD:-—}"; L[$ln]="$tmp"
  printf -v tmp 'Teste:  %s' "${M_TESTCMD:-—}"; LP[$ln]="$tmp"
  ln=$((ln + 1))
  printf -v tmp '%sPlano:%s  %s' "$C_CYAN" "$C_RESET" "${M_INPUT:-—}"; L[$ln]="$tmp"
  printf -v tmp 'Plano:  %s' "${M_INPUT:-—}"; LP[$ln]="$tmp"

  local tn ti to tc toks
  read -r tn ti to tc <<< "$(tokens_summary)"
  printf -v toks '%s in · %s out · %s cache (%s sessões)' \
    "$(human_num "${ti:-0}")" "$(human_num "${to:-0}")" "$(human_num "${tc:-0}")" "${tn:-0}"
  ln=$((ln + 1))
  printf -v tmp '%sTokens:%s %s' "$C_CYAN" "$C_RESET" "$toks"; L[$ln]="$tmp"
  printf -v tmp 'Tokens: %s' "$toks"; LP[$ln]="$tmp"

  # --- TRABALHO ATUAL ----------------------------------------------------
  local cur=0 now
  now=$(date +%s)
  for ((i = 1; i <= P_N; i++)); do
    [ "${P_SEQ[$i]}" = "$CUR_SEQ" ] && cur=$i
  done

  local fase_txt="—" ciclo_txt="—" gates_c="—" gates_p="—" tempo_txt="—"
  if [ "$cur" -gt 0 ]; then
    fase_txt="${P_NUM[$cur]}/${M_TOTAL} · ${P_TITLE[$cur]}"
    ciclo_txt="${P_CYCLE[$cur]}/${M_MAXCYCLES}"
    gates_pair_v gates_c gates_p "${P_GATES[$cur]}"
    if [ "${P_START[$cur]:-0}" -gt 0 ]; then
      tempo_txt="$(fmt_dur $((now - ${P_START[$cur]}))) nesta fase"
    fi
  fi

  rn=$((rn + 1))
  printf -v tmp '%sFase:%s   %s' "$C_CYAN" "$C_RESET" "$fase_txt"; R[$rn]="$tmp"
  printf -v tmp 'Fase:   %s' "$fase_txt"; RP[$rn]="$tmp"
  rn=$((rn + 1))
  printf -v tmp '%sCiclo:%s  %s' "$C_CYAN" "$C_RESET" "$ciclo_txt"; R[$rn]="$tmp"
  printf -v tmp 'Ciclo:  %s' "$ciclo_txt"; RP[$rn]="$tmp"
  rn=$((rn + 1))
  printf -v tmp '%sGates:%s  %s' "$C_CYAN" "$C_RESET" "$gates_c"; R[$rn]="$tmp"
  printf -v tmp 'Gates:  %s' "$gates_p"; RP[$rn]="$tmp"
  rn=$((rn + 1))
  printf -v tmp '%sTempo:%s  %s' "$C_CYAN" "$C_RESET" "$tempo_txt"; R[$rn]="$tmp"
  printf -v tmp 'Tempo:  %s' "$tempo_txt"; RP[$rn]="$tmp"

  local limite_c limite_p
  if [ "$W_ACTIVE" = "1" ]; then
    local left=$((W_UNTIL - now))
    [ "$left" -lt 0 ] && left=0
    printf -v limite_p 'Limite: retoma a MESMA fase em %s (espera %s/%s)' \
      "$(fmt_dur "$left")" "$W_COUNT" "$W_MAX"
    printf -v limite_c '%sLimite:%s %sretoma a MESMA fase em %s (espera %s/%s)%s' \
      "$C_CYAN" "$C_RESET" "$C_RED" "$(fmt_dur "$left")" "$W_COUNT" "$W_MAX" "$C_RESET"
  else
    printf -v limite_p 'Limite: —'
    printf -v limite_c '%sLimite:%s —' "$C_CYAN" "$C_RESET"
  fi
  rn=$((rn + 1)); R[$rn]="$limite_c"; RP[$rn]="$limite_p"

  local log_c log_p abs age src="${L_PATH:-$M_RUNLOG}"
  if abs="$(active_log)"; then
    age=$(file_age "$abs")
    printf -v log_p 'Log:    %s %s (há %s)' "${L_KIND:-ralph}" "$src" "$(fmt_dur "$age")"
    printf -v log_c '%sLog:%s    %s%s%s %s %s(há %s)%s' \
      "$C_CYAN" "$C_RESET" "$C_WHITE" "${L_KIND:-ralph}" "$C_RESET" "$src" \
      "$C_GREY" "$(fmt_dur "$age")" "$C_RESET"
  else
    printf -v log_p 'Log:    —'
    printf -v log_c '%sLog:%s    —' "$C_CYAN" "$C_RESET"
  fi
  rn=$((rn + 1)); R[$rn]="$log_c"; RP[$rn]="$log_p"

  # --- desenha os dois boxes lado a lado ---------------------------------
  local top_l top_r bot_l bot_r bl br line
  box_top_v top_l "$lw" "PROGRESSO"
  box_top_v top_r "$rw" "TRABALHO ATUAL"
  box_bottom_v bot_l "$lw"
  box_bottom_v bot_r "$rw"
  add_top "${top_l} ${top_r}"

  n=$ln; [ "$rn" -gt "$n" ] && n=$rn
  for ((i = 1; i <= n; i++)); do
    box_line_v bl "${L[$i]:-}" "${LP[$i]:-}" "$lw"
    box_line_v br "${R[$i]:-}" "${RP[$i]:-}" "$rw"
    add_top "${bl} ${br}"
  done
  add_top "${bot_l} ${bot_r}"
}

build_table_head() {
  COL_NAME=$((COLS - 19 - COL_ID - COL_STATUS - COL_TRY - COL_TIME - COL_GATES))
  [ "$COL_NAME" -lt 12 ] && COL_NAME=12

  local r_id r_name r_st r_try r_time r_gates sep_t sep_m
  repeat_v r_id    '─' $((COL_ID + 2))
  repeat_v r_name  '─' $((COL_NAME + 2))
  repeat_v r_st    '─' $((COL_STATUS + 2))
  repeat_v r_try   '─' $((COL_TRY + 2))
  repeat_v r_time  '─' $((COL_TIME + 2))
  repeat_v r_gates '─' $((COL_GATES + 2))

  printf -v sep_t '%s┌%s┬%s┬%s┬%s┬%s┬%s┐%s' "$C_CYAN" \
    "$r_id" "$r_name" "$r_st" "$r_try" "$r_time" "$r_gates" "$C_RESET"
  printf -v sep_m '%s├%s┼%s┼%s┼%s┼%s┼%s┤%s' "$C_CYAN" \
    "$r_id" "$r_name" "$r_st" "$r_try" "$r_time" "$r_gates" "$C_RESET"
  printf -v SEP_B '%s└%s┴%s┴%s┴%s┴%s┴%s┘%s' "$C_CYAN" \
    "$r_id" "$r_name" "$r_st" "$r_try" "$r_time" "$r_gates" "$C_RESET"

  local V="${C_CYAN}│${C_RESET}"
  local h_id h_name h_st h_try h_time h_gates line
  pad_v h_id    'ID'          "$COL_ID"
  pad_v h_name  'Fase / Task' "$COL_NAME"
  pad_v h_st    'Status'      "$COL_STATUS"
  pad_v h_try   'Tentativa'   "$COL_TRY"
  pad_v h_time  'Tempo'       "$COL_TIME"
  pad_v h_gates 'Gates'       "$COL_GATES"

  add_top "$sep_t"
  printf -v line '%s %s%s%s %s %s%s%s %s %s%s%s %s %s%s%s %s %s%s%s %s %s%s%s %s' \
    "$V" "$C_CYAN" "$h_id" "$C_RESET" \
    "$V" "$C_CYAN" "$h_name" "$C_RESET" \
    "$V" "$C_CYAN" "$h_st" "$C_RESET" \
    "$V" "$C_CYAN" "$h_try" "$C_RESET" \
    "$V" "$C_CYAN" "$h_time" "$C_RESET" \
    "$V" "$C_CYAN" "$h_gates" "$C_RESET" "$V"
  add_top "$line"
  add_top "$sep_m"
}

build_rows() {
  local V="${C_CYAN}│${C_RESET}" now i j
  now=$(date +%s)
  ROW=(); ROW_N=0; ROW_HL=(); ROW_SEQ=(); PH_ROW_A=(); PH_ROW_B=(); RUN_ROW=0

  # Tracinhos das linhas de task: nao dependem da fase, padeia uma vez.
  local d_try d_time d_gates c_try_tk c_time_tk c_gates_tk
  pad_v d_try   '–' "$COL_TRY"
  pad_v d_time  '–' "$COL_TIME"
  pad_v d_gates '–' "$COL_GATES"
  cell_v c_try_tk   "${C_GREY}${d_try}${C_RESET}"   "$d_try"   "$COL_TRY"
  cell_v c_time_tk  "${C_GREY}${d_time}${C_RESET}"  "$d_time"  "$COL_TIME"
  cell_v c_gates_tk "${C_GREY}${d_gates}${C_RESET}" "$d_gates" "$COL_GATES"

  local st sc sp tries ptime c_id c_name c_st c_try c_time c_gates g_c g_p t_id t_name row hl
  for ((i = 1; i <= P_N; i++)); do
    st="${P_STATUS[$i]}"
    tries="${P_CYCLE[$i]:-0}"
    [ "$tries" = "0" ] && tries="–"

    if [ "$st" = "running" ] && [ "${P_START[$i]:-0}" -gt 0 ]; then
      ptime="$(fmt_dur $((now - ${P_START[$i]})))"
    elif [ "${P_DUR[$i]:-0}" -gt 0 ]; then
      ptime="$(fmt_dur "${P_DUR[$i]}")"
    else
      ptime="–"
    fi

    status_pair_v sc sp "$st"
    gates_pair_v g_c g_p "${P_GATES[$i]}"
    pad_v c_id "F${P_NUM[$i]}" "$COL_ID"
    pad_v t_name "${P_TITLE[$i]}" "$COL_NAME"
    cell_v c_name "${C_WHITE}${t_name}${C_RESET}" "$t_name" "$COL_NAME"
    cell_v c_st "$sc" "$sp" "$COL_STATUS"
    pad_v c_try "$tries" "$COL_TRY"
    pad_v c_time "$ptime" "$COL_TIME"
    cell_v c_gates "$g_c" "$g_p" "$COL_GATES"

    # A linha guarda tudo menos a borda direita: ali vai a barra de rolagem.
    printf -v row '%s %s %s %s %s %s %s %s %s %s %s %s' "$V" \
      "$c_id" "$V" "$c_name" "$V" "$c_st" "$V" "$c_try" "$V" "$c_time" "$V" "$c_gates"

    hl=""
    if [ "$st" = "running" ]; then hl="$C_HILITE"; fi
    add_row "$row" "$hl" "${P_SEQ[$i]}"
    PH_ROW_A[${P_SEQ[$i]}]=$ROW_N
    [ "$st" = "running" ] && RUN_ROW=$ROW_N

    for ((j = 1; j <= T_N; j++)); do
      [ "${T_SEQ[$j]}" = "${P_SEQ[$i]}" ] || continue
      status_pair_v sc sp "${T_STATUS[$j]}"
      pad_v c_id "T${T_IDX[$j]}" "$COL_ID"
      cell_v c_id "${C_GREY}${c_id}${C_RESET}" "$c_id" "$COL_ID"
      pad_v t_name " ↳ ${T_TEXT[$j]}" "$COL_NAME"
      cell_v c_st "$sc" "$sp" "$COL_STATUS"
      printf -v row '%s %s %s %s %s %s %s %s %s %s %s %s' "$V" \
        "$c_id" "$V" "$t_name" "$V" "$c_st" "$V" "$c_try_tk" "$V" "$c_time_tk" "$V" "$c_gates_tk"
      add_row "$row" "" "${P_SEQ[$i]}"
    done
    PH_ROW_B[${P_SEQ[$i]}]=$ROW_N
  done
}

build_log_box() {
  [ "$TAIL_ON" -eq 1 ] && [ "$TAIL_LINES" -gt 0 ] || return 0

  local abs age title top bot line count=0 src="${L_PATH:-$M_RUNLOG}" tmp
  if ! abs="$(active_log)"; then
    box_top_v top "$COLS" "LOG"
    box_bottom_v bot "$COLS"
    add_bot "$top"
    box_line_v tmp "${C_GREY}(nenhum log ativo)${C_RESET}" "(nenhum log ativo)" "$COLS"
    add_bot "$tmp"
    add_bot "$bot"
    return 0
  fi

  age=$(file_age "$abs")
  title="LOG ${L_KIND:-ralph} · ${src} · há $(fmt_dur "$age")"
  box_top_v top "$COLS" "$title"
  box_bottom_v bot "$COLS"
  add_bot "$top"

  while IFS= read -r line; do
    count=$((count + 1))
    box_line_v tmp "${C_GREY}${line}${C_RESET}" "$line" "$COLS"
    add_bot "$tmp"
  done < <(tail -n "$TAIL_LINES" "$abs" 2> /dev/null \
    | tr -d '\r' | expand -t 2 | sed $'s/\033\[[0-9;?]*[a-zA-Z]//g')

  while [ "$count" -lt "$TAIL_LINES" ]; do
    count=$((count + 1))
    if [ "$count" -eq 1 ]; then
      local msg="(sem output ainda)"
      [ "$M_ENGINE" = "claude" ] && [ "${L_KIND:-}" = "impl" ] \
        && msg="(claude em --output-format json: o output so aparece no fim da sessao)"
      box_line_v tmp "${C_GREY}${msg}${C_RESET}" "$msg" "$COLS"
    else
      box_line_v tmp "" "" "$COLS"
    fi
    add_bot "$tmp"
  done

  add_bot "$bot"
}

SEP_B=""

build_frame() {
  TOP=(); TOP_N=0; BOT=(); BOT_N=0
  build_header
  build_panels
  build_table_head
  build_rows
  add_bot "$SEP_B"
  build_log_box
}

# ---------------------------------------------------------------------------
# Desenho
# ---------------------------------------------------------------------------

# tput cols dentro de $(...) le a terminfo (cols#80), nao o tamanho real: o
# command substitution tira o tty do stdout e o 2>/dev/null tira o do stderr,
# entao o ncurses nao tem em que fd rodar o ioctl. stty le do stdin.
read_term_size() {
  read -r LINES_N COLS < <(stty size 2> /dev/null < /dev/tty || echo "30 100")
  [[ "${COLS:-}" =~ ^[0-9]+$ ]] || COLS=100
  [[ "${LINES_N:-}" =~ ^[0-9]+$ ]] || LINES_N=30
  [ -n "${RALPH_WATCH_COLS:-}" ] && [[ "$RALPH_WATCH_COLS" =~ ^[0-9]+$ ]] && COLS="$RALPH_WATCH_COLS"
  [ -n "${RALPH_WATCH_LINES:-}" ] && [[ "$RALPH_WATCH_LINES" =~ ^[0-9]+$ ]] && LINES_N="$RALPH_WATCH_LINES"
  [ "$COLS" -lt 72 ] && COLS=72
  [ "$LINES_N" -lt 12 ] && LINES_N=12
}

# Borda direita da linha visivel: vira barra de rolagem quando ha corte.
scroll_edge_v() { # <destino> <indice absoluto> <visiveis> <total>
  local __i="$2" __vis="$3" __total="$4" __th __top __rel __max
  if [ "$__total" -le "$__vis" ]; then
    printf -v "$1" '%s│%s' "$C_CYAN" "$C_RESET"
    return
  fi
  __th=$((__vis * __vis / __total)); [ "$__th" -lt 1 ] && __th=1
  __max=$((__total - __vis))
  __top=0
  [ "$__max" -gt 0 ] && __top=$((SCROLL * (__vis - __th) / __max))
  __rel=$((__i - SCROLL - 1))
  if [ "$__rel" -ge "$__top" ] && [ "$__rel" -lt $((__top + __th)) ]; then
    printf -v "$1" '%s█%s' "$C_CYAN" "$C_RESET"
  else
    printf -v "$1" '%s│%s' "$C_GREY" "$C_RESET"
  fi
}

# Recorte automatico: mostra o bloco da fase corrente inteiro quando ele cabe;
# quando nao cabe, centra a linha da fase em execucao.
follow_offset() {
  local body="$1" a b
  if [ "$CUR_SEQ" -eq 0 ] || [ -z "${PH_ROW_A[$CUR_SEQ]:-}" ]; then
    SCROLL=0
    [ "$M_STATUS" = "failed" ] && [ "$RUN_ROW" -gt 0 ] && SCROLL=$((RUN_ROW - body / 2))
    return
  fi
  a="${PH_ROW_A[$CUR_SEQ]}"
  b="${PH_ROW_B[$CUR_SEQ]}"
  if [ $((b - a + 1)) -le "$body" ]; then
    SCROLL=$((a - 2))            # uma linha de contexto acima da fase
  else
    SCROLL=$((a - 1))
  fi
}

# clamp_lines <destino> <texto> <max> — corta o texto nas primeiras <max> linhas
# e sem \n no fim. Rede de seguranca do desenho: um quadro com mais linhas que a
# tela faz o terminal ROLAR, e a partir dai o \033[H passa a escrever numa tela
# deslocada — o topo do quadro anterior fica para tras e nenhum \033[K alcanca.
clamp_lines() {
  local __s="$2" __max="$3" __out="" __n=0
  while [ "$__n" -lt "$__max" ]; do
    case "$__s" in
      *$'\n'*) __out="${__out}${__s%%$'\n'*}"$'\n'; __s="${__s#*$'\n'}" ;;
      *)       __out="${__out}${__s}"; __s=""; break ;;
    esac
    __n=$((__n + 1))
  done
  printf -v "$1" '%s' "${__out%$'\n'}"
}

draw() {
  read_term_size

  local eol=$'\033[K'
  if [ "$ONCE" -eq 1 ]; then
    SCROLL=0
    FOLLOW=0
    eol=""
  fi

  build_frame

  # -2: a linha do rodape de rolagem e a folga que o terminal usaria para rolar.
  local body=$((LINES_N - TOP_N - BOT_N - 2))
  [ "$body" -lt 3 ] && body=3
  [ "$ONCE" -eq 1 ] && body=$ROW_N

  if [ "$FOLLOW" -eq 1 ]; then follow_offset "$body"; fi

  local max_scroll=$((ROW_N - body))
  [ "$max_scroll" -lt 0 ] && max_scroll=0
  [ "$SCROLL" -gt "$max_scroll" ] && SCROLL=$max_scroll
  [ "$SCROLL" -lt 0 ] && SCROLL=0

  local out="" i idx edge hl bodytxt
  for ((i = 1; i <= TOP_N; i++)); do out="${out}${TOP[$i]}${eol}"$'\n'; done

  for ((i = 0; i < body; i++)); do
    idx=$((SCROLL + i + 1))
    if [ "$idx" -le "$ROW_N" ]; then
      scroll_edge_v edge "$idx" "$body" "$ROW_N"
      hl="${ROW_HL[$idx]}"
      bodytxt="${ROW[$idx]}"
      if [ -n "$hl" ]; then
        # C_RESET zera tambem o fundo: sem reinjetar o realce depois de cada
        # reset, o destaque da fase viva morria no primeiro separador.
        bodytxt="${bodytxt//"$C_RESET"/$C_RESET$hl}"
        edge="${edge//"$C_RESET"/$C_RESET$hl}"
      fi
      out="${out}${hl}${bodytxt} ${edge}${C_RESET}${eol}"$'\n'
    else
      out="${out}${eol}"$'\n'
    fi
  done

  for ((i = 1; i <= BOT_N; i++)); do out="${out}${BOT[$i]}${eol}"$'\n'; done

  # Rodape de rolagem: depende do recorte, entao so da para montar aqui. No
  # --once (dump) nao ha rolagem nem teclado, entao o rodape nao diz nada.
  if [ "$ONCE" -eq 0 ]; then
    local above=$SCROLL below=$((ROW_N - SCROLL - body)) mode help
    [ "$below" -lt 0 ] && below=0
    if [ "$FOLLOW" -eq 1 ]; then mode="seguindo a fase atual"; else mode="rolagem manual"; fi
    help=" · ↑↓ rolam · f segue · t log"
    if [ "$EMBEDDED" -eq 1 ]; then
      help="${help} · q fecha o painel · Ctrl-C aborta o run"
    else
      help="${help} · q sai (o run continua)"
    fi
    out="${out}${C_GREY}  ▲ ${above} acima · ▼ ${below} abaixo · ${mode}${help}${C_RESET}${eol}"$'\n'
  fi

  if [ "$ONCE" -eq 1 ]; then
    printf '%s' "$out"
  else
    # Sem \n na ultima linha: com o quadro ocupando a tela inteira, ele rolaria
    # o terminal em uma linha e o \033[H seguinte escreveria fora do lugar.
    clamp_lines out "$out" "$LINES_N"
    printf '\033[H%s\033[J' "$out"
  fi
}

# ---------------------------------------------------------------------------
# Loop
# ---------------------------------------------------------------------------

CLEANED=0

cleanup() {
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  if [ "$ONCE" -eq 0 ]; then
    printf '\033[?7h\033[?25h\033[?1049l'
  fi
}

no_state_frame() {
  read_term_size
  local msg=" ${C_YELLOW}sem run publicado em${C_RESET} ${C_GREY}${STATE_FILE#$REPO/}${C_RESET}"
  if [ "$ONCE" -eq 1 ]; then
    printf '%s\n' "$msg"
  else
    printf '\033[H%s\033[K\n\n %s\033[K\n\033[J' \
      "$msg" "${C_GREY}rode o ralph.sh neste repo — o painel engata sozinho. q sai.${C_RESET}"
  fi
}

read_key() {
  local key rest extra
  IFS= read -rsn1 -t "$INTERVAL" key 2> /dev/null || return 1
  if [ "$key" = $'\033' ]; then
    IFS= read -rsn2 -t 1 rest 2> /dev/null || rest=""
    case "$rest" in
      '[A') printf 'up' ;;
      '[B') printf 'down' ;;
      '[H') printf 'home' ;;
      '[F') printf 'end' ;;
      '[5'|'[6'|'[1'|'[4')
        IFS= read -rsn1 -t 1 extra 2> /dev/null || extra=""
        case "$rest" in
          '[5') printf 'pgup' ;;
          '[6') printf 'pgdn' ;;
          '[1') printf 'home' ;;
          '[4') printf 'end' ;;
        esac
        ;;
      *) printf '' ;;
    esac
    return 0
  fi
  printf '%s' "$key"
  return 0
}

if [ "$ONCE" -eq 1 ]; then
  if read_state; then draw; else no_state_frame; fi
  exit 0
fi

# INT/TERM precisam SAIR, nao so limpar: com `trap cleanup INT TERM` o handler
# rodava, devolvia a tela principal — e o loop continuava desenhando quadros por
# cima dela. Era isso que embaralhava o relatorio final do ralph com o painel: o
# `stop_dashboard` mandava o TERM, ficava preso no `wait`, e o painel seguia
# escrevendo na tela normal ate o run acabar.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
printf '\033[?1049h\033[?25l\033[?7l\033[2J'

STDIN_TTY=0
[ -t 0 ] && STDIN_TTY=1
LAST_COLS=0; LAST_LINES=0

while true; do
  if read_state; then
    # Redimensionar reflui o quadro inteiro: o \033[H + \033[J so limpa do
    # cursor para baixo, entao o que a largura antiga quebrou fica na tela.
    read_term_size
    if [ "$COLS" != "$LAST_COLS" ] || [ "$LINES_N" != "$LAST_LINES" ]; then
      printf '\033[2J'
      LAST_COLS=$COLS; LAST_LINES=$LINES_N
    fi
    draw
  else
    no_state_frame
  fi

  # Embutido no ralph: o painel fecha junto com o run.
  if [ "$EMBEDDED" -eq 1 ] && { [ "$M_STATUS" = "done" ] || [ "$M_STATUS" = "failed" ]; }; then
    sleep 1
    break
  fi

  if [ "$STDIN_TTY" -eq 0 ]; then
    sleep "$INTERVAL"
    continue
  fi

  key="$(read_key)" || key=""
  case "$key" in
    q|Q)     break ;;
    up|k)    SCROLL=$((SCROLL - 1)); FOLLOW=0 ;;
    down|j)  SCROLL=$((SCROLL + 1)); FOLLOW=0 ;;
    pgup|b)  SCROLL=$((SCROLL - 10)); FOLLOW=0 ;;
    pgdn|d|' ')
             SCROLL=$((SCROLL + 10)); FOLLOW=0 ;;
    home|g)  SCROLL=0; FOLLOW=0 ;;
    end|G)   SCROLL=$ROW_N; FOLLOW=0 ;;
    f|F)     FOLLOW=$((1 - FOLLOW)) ;;
    t|T)     TAIL_ON=$((1 - TAIL_ON)) ;;
  esac
done

exit 0
