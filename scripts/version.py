"""The QingType product version and checks used by builds and releases."""
import argparse
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION_PATTERN = r'(?:0|[1-9][0-9]{0,3})\.(?:0|[1-9][0-9]?)\.(?:0|[1-9][0-9]?)'


def product_version():
    value = (ROOT / 'VERSION').read_text(encoding='utf-8').removesuffix('\n')
    if not re.fullmatch(VERSION_PATTERN, value):
        raise ValueError('VERSION must be three numeric components (major.minor.patch)')
    return value


def check_bundles(version, bundles):
    for bundle in bundles:
        path = Path(bundle) / 'Contents/Info.plist'
        with path.open('rb') as source:
            info = plistlib.load(source)
        for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
            if info.get(key) != version:
                raise ValueError(f'{path}: {key} is {info.get(key)!r}, expected {version!r}')


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('read')
    tag_parser = commands.add_parser('check-tag')
    tag_parser.add_argument('tag')
    bundles_parser = commands.add_parser('check-bundles')
    bundles_parser.add_argument('bundles', nargs='+')
    name_parser = commands.add_parser('package-name')
    name_parser.add_argument('architecture', choices=['arm64'])
    args = parser.parse_args()
    version = product_version()
    if args.command == 'read':
        print(version)
    elif args.command == 'check-tag':
        if not re.fullmatch(r'v' + re.escape(version) + r'-preview\.[0-9]+', args.tag):
            raise ValueError(f'preview tag {args.tag!r} does not match VERSION {version}')
    elif args.command == 'check-bundles':
        check_bundles(version, args.bundles)
    elif args.command == 'package-name':
        print(f'QingType-{version}-{args.architecture}.dmg')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f'Version check failed: {error}', file=sys.stderr)
        sys.exit(1)
