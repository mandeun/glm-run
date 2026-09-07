#!/bin/bash
# glm-run.sh — 프롬프트 한 장을 GLM 에게 맡기고, 결과를 검사기로 받아냅니다.
#
#   ./glm-run.sh 프롬프트.md            진짜 시킵니다 (z.ai 할당량이 나갑니다)
#   ./glm-run.sh 프롬프트.md --dry-run  GLM 을 안 부르고 나머지 절차만 돌려봅니다
#
# 지금 폴더에서 일합니다. 검사 목록은 같은 폴더의 glm-gates.txt 에 적습니다.
#
# 순서: 지금 초록불인지 확인 → 스냅샷 → GLM → 다시 검사 → 빨간불이면 되돌리는 법 안내.
# GLM 이 "다 됐다"고 말해도 그 말은 안 믿습니다. 검사기가 통과해야 통과입니다.

set -uo pipefail

ENVFILE="${GLM_ENV_FILE:-$HOME/.config/glm/env}"
GATEFILE=glm-gates.txt

# GLM 에게 허용하는 도구. 여기 없는 건 GLM 이 못 합니다 (rm, curl, git push 등).
ALLOWED=(Read Write Edit Glob Grep
         "Bash(python3:*)" "Bash(node:*)" "Bash(uv:*)"
         "Bash(ls:*)" "Bash(cat:*)" "Bash(mkdir:*)" "Bash(grep:*)")

PROMPT="${1:-}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1

die() { echo "✗ $*" >&2; exit 1; }

[ -n "$PROMPT" ] || die "프롬프트 파일을 주세요.  예: ./glm-run.sh prompts/01.md"
[ -r "$PROMPT" ] || die "$PROMPT 를 읽을 수 없습니다."
[ -r "$ENVFILE" ] || die "$ENVFILE 이 없습니다. README 의 «키 저장»을 하세요."
[ -r "$GATEFILE" ] || die "$GATEFILE 이 없습니다. 통과해야 할 명령을 한 줄에 하나씩 적으세요.
   검사가 없으면 GLM 이 뭘 망쳐도 알 수 없습니다. 그래서 없으면 시작하지 않습니다."
command -v claude >/dev/null || die "claude 명령이 없습니다."

# 검사 목록 읽기 (# 주석과 빈 줄은 넘깁니다)
GATES=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  GATES+=("$line")
done < "$GATEFILE"
[ "${#GATES[@]}" -gt 0 ] || die "$GATEFILE 에 검사가 한 줄도 없습니다."

run_gates() {   # $1 = 로그 파일
  local failed=0 g
  for g in "${GATES[@]}"; do
    printf '  %-34s' "$g"
    if eval "$g" >>"$1" 2>&1; then echo "OK"; else echo "실패"; failed=1; fi
  done
  return $failed
}

TS=$(date +%Y%m%d-%H%M%S)
RUNDIR=".glm/runs/$TS"
mkdir -p "$RUNDIR" .glm/snapshots || die "작업 폴더를 못 만들었습니다."
echo "작업 폴더: $PWD"

# 1. 시작할 때 이미 빨간 줄이면 멈춥니다. 안 그러면 GLM 탓인지 구분이 안 됩니다.
echo "[1/5] 지금 상태 확인"
run_gates "$RUNDIR/before.log" || die "시작부터 실패한 검사가 있습니다. 그것부터 고치세요 → $RUNDIR/before.log"

# 2. 되돌릴 자리. git 저장소가 아니어도 되돌릴 수 있게 통째로 떠 둡니다.
SNAP=".glm/snapshots/$TS.tar.gz"
echo "[2/5] 스냅샷 → $SNAP"
tar --exclude=./.glm --exclude=./.git --exclude=./__pycache__ --exclude=./.venv \
    --exclude=./node_modules -czf "$SNAP" . 2>/dev/null \
    || die "스냅샷 실패 — GLM 을 부르지 않았습니다."

# 3. GLM 에게 맡깁니다.
echo "[3/5] GLM 실행 (프롬프트: $PROMPT)"
if [ "$DRY" = 1 ]; then
  echo "  --dry-run 이라 GLM 을 부르지 않았습니다."
  echo "(dry-run: GLM 호출 없음)" > "$RUNDIR/output.md"
else
  ( . "$ENVFILE"
    ANTHROPIC_BASE_URL="$GLM_BASE_URL" \
    API_TIMEOUT_MS=3000000 \
    claude -p "$(cat "$PROMPT")" \
      --model "$GLM_MODEL" \
      --permission-mode acceptEdits \
      --allowedTools "${ALLOWED[@]}" ) 2>&1 | tee "$RUNDIR/output.md"
  [ "${PIPESTATUS[0]}" = 0 ] || echo "  (GLM 이 오류로 끝났습니다 — 아래 검사 결과를 보세요)"
fi

# 4. GLM 말 말고 검사기 말을 듣습니다.
echo "[4/5] 끝난 뒤 상태 확인"
if run_gates "$RUNDIR/after.log"; then RESULT=통과; else RESULT=실패; fi

# 5. 기록을 남긴 «뒤에» 결과를 말합니다.
{
  echo "# GLM 작업 $TS"
  echo
  echo "- 프롬프트: $PROMPT"
  echo "- dry-run: $DRY"
  echo "- 결과: $RESULT"
  echo "- 스냅샷: $SNAP"
  echo "- 바뀐 파일:"
  find . -newer "$SNAP" -type f -not -path "./.glm/*" -not -path "./.git/*" \
       -not -path "./__pycache__/*" -not -path "./.venv/*" -not -path "./node_modules/*" \
    | sed 's/^/  - /'
} > "$RUNDIR/report.md"
sync

echo "[5/5] $RESULT — 기록: $RUNDIR/report.md"
if [ "$RESULT" = 실패 ]; then
  echo
  echo "되돌리려면:"
  echo "  tar -xzf $PWD/$SNAP -C $PWD"
  exit 1
fi
