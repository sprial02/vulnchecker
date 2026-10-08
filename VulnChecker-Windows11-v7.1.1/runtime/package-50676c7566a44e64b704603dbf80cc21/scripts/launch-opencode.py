"""Load saved keys into the child process, without exposing keys in argv."""
import argparse
import json
import os
from pathlib import Path
import sys


def prepare(config_path, arguments, inherited=None):
    config = json.loads(Path(config_path).read_text(encoding='utf-8-sig'))
    env = dict(os.environ if inherited is None else inherited)
    overlay = json.loads(env.get('OPENCODE_CONFIG_CONTENT') or '{}')
    providers = overlay.setdefault('provider', {})
    for provider, variable in [('ibm-ica', 'IBM_ICA_API_KEY'), ('deepseek', 'DEEPSEEK_API_KEY')]:
        entry = config.get('provider', {}).get(provider)
        if not entry:
            continue
        entry = json.loads(json.dumps(entry))
        ref = entry['options']['apiKey']
        if not ref.startswith('{file:') or not ref.endswith('}'):
            raise ValueError('Expected managed credential file reference')
        key = Path(ref[6:-1]).read_text(encoding='utf-8').strip()
        if not key:
            raise ValueError('Saved API key is empty')
        env[variable] = key
        entry['options']['apiKey'] = '{env:' + variable + '}'
        providers[provider] = entry
    model = config['model']
    overlay.update(model=model, small_model=config.get('small_model', model))
    env['OPENCODE_CONFIG'] = str(config_path)
    env['OPENCODE_CONFIG_CONTENT'] = json.dumps(overlay)
    args = list(arguments)
    if not any(a in ('--model', '-m') or a.startswith(('--model=', '-m=')) for a in args):
        args = ['--model', model] + args
    return env, args


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    parser.add_argument('--executable', required=True)
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    options = parser.parse_args()
    args = options.arguments
    if args[:1] == ['--']:
        args = args[1:]
    try:
        env, args = prepare(options.config, args)
    except Exception:
        sys.exit('OpenCode API key loading failed. Save AI settings and relaunch from VulnChecker.')
    os.execvpe(options.executable, [options.executable] + args, env)


if __name__ == '__main__':
    main()
