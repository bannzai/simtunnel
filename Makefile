# 引数なしの make で動作確認 (verify) を実行する
.DEFAULT_GOAL := verify

.PHONY: verify
verify:
	python3 runner/test/test-agentd.py
	bash runner/test/test-build-app.sh
