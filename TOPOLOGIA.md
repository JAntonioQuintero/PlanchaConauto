# Topología de ejecución

```text
[172.20.54.160] Semaphore UI / Ansible controller
        |
        | ansible-playbook por SSH
        v
[172.20.54.217] Servidor QA / destino del planchado
        |
        | scp/ssh solo lectura
        v
[172.20.54.202] Servidor Producción / origen de respaldos
```

## Reglas

1. El grupo `planchado_conauto` del inventario debe contener solo `172.20.54.217`.
2. El servidor `172.20.54.202` no debe recibir comandos de planchado, apagado o restauración.
3. El servidor `172.20.54.160` no debe almacenar respaldos ni ejecutar `prorest`.
4. QA debe tener una llave de solo lectura para consultar/copiar respaldos desde Producción.
5. El operador debe iniciar primero con `dry_run=true`.
