include:
  {% if 'build_image' not in grains.get('product_version') | default('', true) %}
  - repos
  {% endif %}
  - server_containerized.install_mgradm
  - server_containerized.initial_content
  - server_containerized.testsuite
