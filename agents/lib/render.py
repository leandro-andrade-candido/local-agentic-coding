#!/usr/bin/env python3
"""Gera um arquivo de configuração a partir de modelos.

Uso: render.py SAIDA MODELO [MODELO...]

JSON (SAIDA não termina em .toml nem .rules):
- Os modelos são mesclados em ordem: objetos se mesclam recursivamente; listas
  e valores simples do modelo posterior substituem os anteriores. Assim um
  perfil (interactive/autonomous) sobrepõe a base.
- "@@NOME@@" dentro de qualquer string (inclusive chaves) vira o valor da
  variável de ambiente NOME. Uma string que seja exatamente "@@INT:NOME@@"
  vira número inteiro. Variável ausente é erro.
- Chaves que começam com "//" são comentários e são removidas da saída.

Texto (SAIDA .toml ou .rules): os modelos são concatenados e "@@NOME@@" é
trocado pelo valor com escape de string TOML/Starlark (\\ e "); "@@INT:NOME@@"
exige um inteiro. Os modelos devem pôr os marcadores dentro de aspas duplas.
"""
import json
import os
import re
import sys

PLACEHOLDER = re.compile(r"@@([A-Z][A-Z0-9_]*)@@")
INT_PLACEHOLDER = re.compile(r"^@@INT:([A-Z][A-Z0-9_]*)@@$")
INT_TEXT = re.compile(r"@@INT:([A-Z][A-Z0-9_]*)@@")


def env(name: str) -> str:
    value = os.environ.get(name)
    if value is None:
        sys.exit(f"render.py: variável de ambiente {name} não definida")
    return value


def env_int(name: str) -> int:
    value = env(name)
    if not re.fullmatch(r"-?[0-9]+", value):
        sys.exit(f"render.py: {name}={value!r} não é inteiro")
    return int(value)


def subst(value):
    if isinstance(value, dict):
        return {subst(k): subst(v) for k, v in value.items() if not k.startswith("//")}
    if isinstance(value, list):
        return [subst(v) for v in value]
    if isinstance(value, str):
        m = INT_PLACEHOLDER.match(value)
        if m:
            return env_int(m.group(1))
        return PLACEHOLDER.sub(lambda m: env(m.group(1)), value)
    return value


def merge(base, over):
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = merge(base[k], v) if k in base else v
        return out
    return over


def render_text(inputs):
    parts = []
    for path in inputs:
        with open(path, encoding="utf-8") as fh:
            parts.append(fh.read())
    text = "\n".join(parts)
    text = INT_TEXT.sub(lambda m: str(env_int(m.group(1))), text)
    return PLACEHOLDER.sub(lambda m: env(m.group(1)).replace("\\", "\\\\").replace('"', '\\"'), text)


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out_path, inputs = sys.argv[1], sys.argv[2:]
    if out_path.endswith((".toml", ".rules")):
        content = render_text(inputs)
    else:
        result = {}
        for path in inputs:
            with open(path, encoding="utf-8") as fh:
                result = merge(result, json.load(fh))
        content = json.dumps(subst(result), indent=2, ensure_ascii=False) + "\n"
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.replace(tmp, out_path)


if __name__ == "__main__":
    main()
