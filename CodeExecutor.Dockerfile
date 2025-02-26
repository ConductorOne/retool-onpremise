FROM tryretool/code-executor-service:3.114.8-stable

COPY ./start-fix.sh /retool/code_executor/start.sh

CMD bash start.sh