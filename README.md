# apic-storage-check

Check MRPE (Check_MK) de **disco cheio nas APICs** — detecta o fault ACI **F1529**
(equipment-full), o mesmo que a Cisco usa pra apontar o bug **CSCwe09535**
(versão 5.2 lota `/dev/vg_ifc0/boot`, ex.: `40G 38G 0 100% /bin`) e que também
pega fabrics com outros filesystems comprometidos (caso TESP6/TESP7).

Serve pra gerar o incidente automático de disco cheio que justifica o reload
das APICs (reload de 1 node por fabric por vez; APIC fora do data plane).

## Estados

| Fault F1529 no fabric              | Serviço |
|------------------------------------|---------|
| algum `critical`/`major`           | CRIT    |
| só `minor`/`warning`               | WARN    |
| nenhum                             | OK      |
| APIC inacessível / login falhou    | UNKNOWN |

Saída inclui node (ex.: `APIC01TESP2`), severidade e descrição do fault, com
perfdata `faults` e `max_usage`.

## Instalação (na dev-redes, box a box: git pull + install)

```bash
cd monitoramento12/coletores/apic-storage-check
sudo bash install.sh          # pede usuário/senha da APIC na 1ª vez
sudo vi /etc/check_mk/apic_storage.conf   # preencher IPs das APICs (FABRIC_*)
sudo bash install.sh          # regenera o mrpe com os fabrics preenchidos
```

Arquivos instalados:

- `/usr/local/bin/check_apic_storage.sh` — o check
- `/etc/check_mk/apic_storage.conf` — credenciais + `FABRIC_<NOME>=https://<ip>` (chmod 600)
- bloco `# BEGIN/END apic-storage-check` no `/etc/check_mk/mrpe.cfg` com um serviço
  `CAPACITY%20DISCO%20APIC%20<FABRIC> (interval=300)` por fabric — mesmo formato dos
  checks de memória existentes; o installer só mexe dentro do bloco dele

Depois é só fazer o service discovery do host no Check_MK.

## Teste manual

```bash
/usr/local/bin/check_apic_storage.sh TESP2; echo "exit=$?"
```
