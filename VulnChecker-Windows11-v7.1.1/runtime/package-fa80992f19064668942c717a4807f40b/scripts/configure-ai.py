"""Configure managed OpenAI-compatible providers without embedding credentials."""
import json
import os
import pathlib
import shutil
import sys
import time

ICA_MODELS = ('gemini-3.1-pro-preview', 'claude-sonnet-4-6', 'claude-sonnet-5')
DEEPSEEK_MODELS = ('deepseek-flash', 'deepseek-v4-pro')


def configure(path, credentials, data):
    config = json.loads(path.read_text(encoding='utf-8-sig')) if path.exists() else {}
    if not isinstance(config, dict) or not isinstance(config.get('provider', {}), dict):
        raise ValueError('Invalid OpenCode configuration')
    available = {f'ibm-ica/{m}' for m in ICA_MODELS} | {f'deepseek/{m}' for m in DEEPSEEK_MODELS}
    model = data['model']
    if model not in available:
        raise ValueError('Unsupported model')
    specs = (
        ('ibm-ica', 'IBM ICA', 'https://api.nextgen-beta.ica.ibm.com/ica/v1', ICA_MODELS, 'ibmKey'),
        ('deepseek', 'DeepSeek (backup)', 'https://api.deepseek.com', DEEPSEEK_MODELS, 'deepseekKey'),
    )
    for provider, _, _, _, field in specs:
        key = data.get(field, '')
        if not isinstance(key, str) or any(c in key for c in '\r\n\0'):
            raise ValueError('Invalid API key')
        if model.startswith(provider + '/') and not key:
            raise ValueError('Selected provider requires an API key')
    credentials.mkdir(parents=True, exist_ok=True, mode=0o700)
    credentials.chmod(0o700)
    providers = config.setdefault('provider', {})
    for provider, name, url, models, field in specs:
        key_path = credentials / (provider + '.key')
        key = data.get(field, '')
        if key:
            # No key in stdout, argv, config backups, or world-readable temp files.
            temp = key_path.with_suffix('.tmp')
            fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                stream.write(key)
            temp.chmod(0o600)
            temp.replace(key_path)
            providers[provider] = {
                'npm': '@ai-sdk/openai-compatible', 'name': name,
                'options': {'baseURL': url, 'apiKey': '{file:' + key_path.as_posix() + '}'},
                'models': {m: {'name': m, 'tool_call': True} for m in models},
                'whitelist': list(models),
            }
        else:
            providers.pop(provider, None)
            key_path.unlink(missing_ok=True)
    config.setdefault('$schema', 'https://opencode.ai/config.json')
    config['model'] = model
    config['small_model'] = model
    payload = json.dumps(config, ensure_ascii=False, indent=2) + '\n'
    if path.exists() and path.read_text(encoding='utf-8-sig') == payload:
        return
    if path.exists():
        shutil.copy2(path, path.with_name(path.name + '.backup-' + str(time.time_ns())))
    temp = path.with_name(path.name + '.ai-tmp')
    temp.write_text(payload, encoding='utf-8')
    temp.replace(path)


if __name__ == '__main__':
    try:
        configure(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), json.load(sys.stdin))
    except Exception:
        # Never echo input or credential values in diagnostics.
        sys.exit('AI configuration failed; check configuration and key settings.')
