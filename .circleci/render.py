#!/usr/bin/python

import jinja2

base_actions = [
    'full-test',
    'coda-peers-test',
    'coda-transitive-peers-test',
    'coda-block-production-test',
    'coda-shared-prefix-test -who-proposes 0',
    'coda-shared-prefix-test -who-proposes 1',
    'coda-shared-state-test',
    'coda-restart-node-test',
    'transaction-snark-profiler -check-only'
]

build_profiles = [
    'dev',
    'testnet_posig',
    'testnet_postake',
    'testnet_public'
]

tests = [
   {
       'friendly': 'Fake Hash',
       'config': 'fake_hash',
       'name': 'fake_hash_full_test',
       'actions': ['full-test']
   },
   {
       'friendly': 'Proof of Signature Tests',
       'config': 'test_posig_snarkless',
       'name': 'posig_integration_tests',
       'actions': base_actions
   },
   {
       'friendly': 'Proof of Stake Tests',
       'config': 'test_postake_snarkless',
       'name': 'postake_integration_tests',
       'actions': base_actions
   }
]

# Render it
env = jinja2.Environment(loader=jinja2.FileSystemLoader('.'))
template = env.get_template('./config.yml.jinja')
rendered = template.render(tests=tests, build_profiles=build_profiles)
print(rendered)
