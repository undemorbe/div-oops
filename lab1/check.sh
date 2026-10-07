#!/bin/bash
cd "$(dirname "$0")"

c="curl -sk --max-time 5"
for h in todo.local project2.local evil.local; do
    c="$c --resolve $h:80:127.0.0.1 --resolve $h:443:127.0.0.1"
done

ok=0
bad=0
pass() { echo "  [ok] $1"; ok=$((ok+1)); }
fail() { echo "  [FAIL] $1"; bad=$((bad+1)); }
code() { $c -o /dev/null -w '%{http_code}' "$@"; }

whoami6() {
    for i in 1 2 3 4 5 6; do
        $c -w ' %{http_code}\n' https://todo.local/api/whoami
    done
}


echo
echo "--- 1. http -> https ---"
echo "\$ curl -I http://todo.local/test?a=1"
$c -I "http://todo.local/test?a=1" | grep -iE '^(HTTP|location)'
if [ "$(code http://todo.local/test?a=1)" = 301 ]; then pass "301"; else fail "нет 301"; fi
loc=$($c -I "http://todo.local/test?a=1" | grep -i '^location' | tr -d '\r')
if [ "$loc" = "Location: https://todo.local/test?a=1" ]; then pass "редирект на https, путь сохранился"; else fail "location: $loc"; fi
if [ "$(code https://todo.local/)" = 200 ]; then pass "https://todo.local/ открывается"; else fail "https://todo.local/ не 200"; fi


echo
echo "--- 2. балансировка /api ---"
echo "\$ curl https://todo.local/api/whoami  (6 раз)"
out=$(whoami6)
echo "$out"
n=$(echo "$out" | grep -o '"instance":"[^"]*"' | sort -u | wc -l)
if [ $n -eq 2 ]; then pass "ответили оба бэкенда"; else fail "ответил только $n бэкенд"; fi
sleep 3   # чтобы limit_req не мешал следующим проверкам


echo
echo "--- 3. гасим один бэкенд ---"
if [ -n "$SKIP_FAILOVER" ]; then
    echo "  пропускаю (SKIP_FAILOVER), гаси руками через Ctrl+C"
else
    ./lab.sh backend stop 1
    out=$(whoami6)
    echo "$out"
    if ! echo "$out" | grep -qv ' 200$'; then pass "все запросы 200"; else fail "есть ответы не 200"; fi
    if ! echo "$out" | grep -q backend-1; then pass "отвечает только backend-2"; else fail "backend-1 всё ещё отвечает?"; fi
    if [ "$(code https://todo.local/)" = 200 ]; then pass "сайт живой"; else fail "сайт лёг"; fi
    ./lab.sh backend start 1
fi
sleep 3


echo
echo "--- 4. /admin ---"
r=$(code https://todo.local/admin/)
echo "без пароля: $r"
if [ "$r" = 401 ]; then pass "без пароля 401"; else fail "без пароля $r"; fi
r=$(code -u admin:wrong https://todo.local/admin/)
echo "неправильный пароль: $r"
if [ "$r" = 401 ]; then pass "с неправильным паролем 401"; else fail "с неправильным паролем $r"; fi
if [ -n "$ADMIN_PASSWORD" ]; then
    r=$(code -u "admin:$ADMIN_PASSWORD" https://todo.local/admin/)
    echo "правильный пароль: $r"
    if [ "$r" = 200 ]; then pass "с паролем пускает"; else fail "с паролем $r"; fi
fi


echo
echo "--- 5. флуд /api ---"
echo "40 запросов одновременно:"
codes=$(for i in $(seq 40); do $c -o /dev/null -w '%{http_code}\n' https://todo.local/api/tasks & done; wait)
echo "$codes" | sort | uniq -c
if echo "$codes" | grep -q 429; then pass "есть 429"; else fail "429 не было"; fi
if echo "$codes" | grep -q 200; then pass "часть прошла"; else fail "не прошёл ни один"; fi
sleep 3


echo
echo "--- 6. виртуальные хосты ---"
if $c https://project2.local/ | grep -q "Project Two"; then pass "project2.local отдаёт свой сайт"; else fail "project2.local"; fi
if $c https://todo.local/ | grep -q "<title>TODO List"; then pass "todo.local отдаёт todo"; else fail "todo.local"; fi
if $c -H "Host: project2.local" https://todo.local/ | grep -q "Project Two"; then pass "Host: project2.local -> project2"; else fail "Host: project2.local"; fi
for p in /api/tasks /docs/ /admin/; do
    r=$(code https://project2.local$p)
    if [ "$r" = 404 ]; then pass "project2.local$p = 404"; else fail "project2.local$p = $r"; fi
done

$c --http1.1 -o /dev/null -H "Host: evil.local" https://todo.local/
r=$?
if [ $r -eq 52 ]; then pass "Host: evil.local -> соединение закрыто"; else fail "Host: evil.local, curl вернул $r"; fi
$c -o /dev/null https://evil.local/ 2>/dev/null
r=$?
if [ $r -eq 35 ]; then pass "https://evil.local -> tls отклонён"; else fail "https://evil.local, curl вернул $r"; fi
$c -o /dev/null http://evil.local/
r=$?
if [ $r -eq 52 ]; then pass "http://evil.local -> без редиректа"; else fail "http://evil.local, curl вернул $r"; fi


echo
echo "--- 7. alias и 404 ---"
if $c https://todo.local/docs/ | grep -q alias; then pass "/docs/ через alias"; else fail "/docs/"; fi
r=$(code https://todo.local/nope)
echo "\$ curl https://todo.local/nope -> $r"
if [ "$r" = 404 ]; then pass "404"; else fail "ждал 404, пришло $r"; fi
if $c https://todo.local/nope | grep -q "Такой страницы нет"; then pass "страница 404 своя"; else fail "страница 404 стандартная"; fi


echo
echo "итого: ok $ok, fail $bad"
[ $bad -eq 0 ]
