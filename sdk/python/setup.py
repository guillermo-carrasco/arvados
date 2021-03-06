from setuptools import setup, find_packages

setup(name='arvados-python-client',
      version='0.1',
      description='Arvados client library',
      author='Arvados',
      author_email='info@arvados.org',
      url="https://arvados.org",
      download_url="https://github.com/curoverse/arvados.git",
      license='Apache 2.0',
      packages=find_packages(),
      scripts=[
        'bin/arv-get',
        'bin/arv-keepdocker',
        'bin/arv-ls',
        'bin/arv-normalize',
        'bin/arv-put',
        'bin/arv-ws',
        ],
      install_requires=[
        'python-gflags',
        'google-api-python-client',
        'httplib2',
        'urllib3',
        'ws4py'
        ],
      zip_safe=False)
