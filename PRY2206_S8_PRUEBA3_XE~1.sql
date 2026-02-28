/* ============================================================
   PRY2206 – Semana 8 (Actividad Sumativa)

   Autor : IGNACIO ESTEBAN MIÑO ASTORGA
   Carrera: ANALISTA PROGRAMADOR COMPUTACIONAL
   Fecha : 28-02-2026

   Objetivo:
   1) Caso 1: Trigger que mantiene TOTAL_CONSUMOS al insertar,
      actualizar o eliminar consumos.
   2) Caso 2: Funciones + Package + Procedimiento que calcula y
      carga la cobranza diaria en DETALLE_DIARIO_HUESPEDES,
      registrando errores en REG_ERRORES.
   ============================================================ */


/* ============================================================
   CASO 1: TRIGGER TRG_CONSUMO_TOTAL
   - Mantiene actualizado TOTAL_CONSUMOS por cada huésped
   - Soporta INSERT / UPDATE / DELETE en CONSUMO
   ============================================================ */
CREATE OR REPLACE TRIGGER trg_consumo_total
AFTER INSERT OR UPDATE OR DELETE ON consumo
FOR EACH ROW
DECLARE
  v_diff NUMBER;
BEGIN
  IF INSERTING THEN
    v_diff := :NEW.monto;
  ELSIF UPDATING THEN
    v_diff := :NEW.monto - :OLD.monto;
  ELSIF DELETING THEN
    v_diff := -(:OLD.monto);
  END IF;

  IF INSERTING OR UPDATING THEN
    UPDATE total_consumos
       SET monto_consumos = monto_consumos + v_diff
     WHERE id_huesped = :NEW.id_huesped;

    IF SQL%ROWCOUNT = 0 THEN
      INSERT INTO total_consumos(id_huesped, monto_consumos)
      VALUES (:NEW.id_huesped, v_diff);
    END IF;

  ELSIF DELETING THEN
    UPDATE total_consumos
       SET monto_consumos = monto_consumos + v_diff
     WHERE id_huesped = :OLD.id_huesped;

    IF SQL%ROWCOUNT = 0 THEN
      INSERT INTO total_consumos(id_huesped, monto_consumos)
      VALUES (:OLD.id_huesped, v_diff);
    END IF;
  END IF;
END;
/
SHOW ERRORS;


/* ============================================================
   PRUEBA DEL TRIGGER (según instrucción del caso)
   1) Insertar consumo nuevo para cliente 340006, reserva 1587, monto 150
   2) Eliminar consumo id 11473
   3) Actualizar consumo id 10688 a monto 95
   ============================================================ */
DECLARE
  v_new_id NUMBER;
BEGIN
  SELECT NVL(MAX(id_consumo),0) + 1 INTO v_new_id FROM consumo;

  INSERT INTO consumo(id_consumo, id_reserva, id_huesped, monto)
  VALUES (v_new_id, 1587, 340006, 150);

  DELETE FROM consumo
   WHERE id_consumo = 11473;

  UPDATE consumo
     SET monto = 95
   WHERE id_consumo = 10688;

  COMMIT;
END;
/
SHOW ERRORS;


/* ============================================================
   CASO 2: FUNCIONES / PACKAGE / PROCEDIMIENTO

   Reglas principales:
   - Proceso recibe fecha (p_fecha_proceso) y tipo de cambio (p_tipo_cambio)
   - Limpia DETALLE_DIARIO_HUESPEDES y REG_ERRORES para permitir re-ejecución
   - Calcula:
     alojamiento = (valor_habitacion + valor_minibar) * estadia
     consumos    = TOTAL_CONSUMOS
     tours       = suma tours por huésped (valor_tour * num_personas)
     valor extra = 35.000 CLP por persona convertido a USD y sumado
   - Descuentos:
     por consumos según TRAMOS_CONSUMOS
     por agencia: “VIAJES ALBERTI” => 12% del subtotal
   - Finalmente convierte todo a CLP y redondea a enteros
   ============================================================ */


/* ------------------------------------------------------------
   FUNCIÓN: FN_AGENCIA_HUESPED
   - Retorna nombre de agencia del huésped
   - Si no tiene agencia => “NO REGISTRA AGENCIA”
   - Si ocurre un error, registra en REG_ERRORES y retorna el mismo texto
   ------------------------------------------------------------ */
CREATE OR REPLACE FUNCTION fn_agencia_huesped(
  p_id_huesped IN huesped.id_huesped%TYPE
)
RETURN VARCHAR2
IS
  v_agencia agencia.nom_agencia%TYPE;
  v_msg     VARCHAR2(4000);
  PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
  SELECT a.nom_agencia
    INTO v_agencia
    FROM huesped h
    LEFT JOIN agencia a ON a.id_agencia = h.id_agencia
   WHERE h.id_huesped = p_id_huesped;

  IF v_agencia IS NULL THEN
    RETURN 'NO REGISTRA AGENCIA';
  END IF;

  RETURN v_agencia;

EXCEPTION
  WHEN OTHERS THEN
    v_msg := 'HUESPED='||p_id_huesped||' - '||SUBSTR(SQLERRM,1,3500);

    INSERT INTO reg_errores(id_error, nomsubprograma, msg_error)
    VALUES (sq_error.NEXTVAL, 'FN_AGENCIA_HUESPED', v_msg);

    COMMIT;
    RETURN 'NO REGISTRA AGENCIA';
END;
/
SHOW ERRORS;


/* ------------------------------------------------------------
   FUNCIÓN: FN_CONSUMOS_HUESPED
   - Devuelve consumo total del huésped desde TOTAL_CONSUMOS
   - Si no existe registro => 0
   ------------------------------------------------------------ */
CREATE OR REPLACE FUNCTION fn_consumos_huesped(
  p_id_huesped IN total_consumos.id_huesped%TYPE
)
RETURN NUMBER
IS
  v_consumos total_consumos.monto_consumos%TYPE;
BEGIN
  SELECT monto_consumos
    INTO v_consumos
    FROM total_consumos
   WHERE id_huesped = p_id_huesped;

  RETURN NVL(v_consumos,0);

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN 0;
  WHEN OTHERS THEN
    RETURN 0;
END;
/
SHOW ERRORS;


/* ------------------------------------------------------------
   FUNCIÓN: FN_DESC_CONSUMOS
   - Calcula descuento por consumos en USD según TRAMOS_CONSUMOS
   - Busca el % donde p_consumos_usd esté dentro de vmin/vmax
   - Si no calza con tramo => 0
   ------------------------------------------------------------ */
CREATE OR REPLACE FUNCTION fn_desc_consumos(p_consumos_usd IN NUMBER)
RETURN NUMBER
IS
  v_pct tramos_consumos.pct%TYPE;
BEGIN
  IF NVL(p_consumos_usd,0) <= 0 THEN
    RETURN 0;
  END IF;

  SELECT t.pct
    INTO v_pct
    FROM tramos_consumos t
   WHERE p_consumos_usd BETWEEN t.vmin_tramo AND t.vmax_tramo;

  RETURN ROUND(p_consumos_usd * NVL(v_pct,0));

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN 0;
  WHEN OTHERS THEN
    RETURN 0;
END;
/
SHOW ERRORS;


/* ------------------------------------------------------------
   PACKAGE: PKG_COBRANZA_HOTEL
   - Incluye función pública para calcular monto de tours (USD)
   ------------------------------------------------------------ */
CREATE OR REPLACE PACKAGE pkg_cobranza_hotel AS
  g_tours_usd NUMBER;

  FUNCTION fn_tours_huesped(
    p_id_huesped IN huesped.id_huesped%TYPE
  ) RETURN NUMBER;
END pkg_cobranza_hotel;
/
SHOW ERRORS;

CREATE OR REPLACE PACKAGE BODY pkg_cobranza_hotel AS
  FUNCTION fn_tours_huesped(
    p_id_huesped IN huesped.id_huesped%TYPE
  ) RETURN NUMBER
  IS
    v_total NUMBER;
  BEGIN
    SELECT NVL(SUM(t.valor_tour * NVL(ht.num_personas,1)),0)
      INTO v_total
      FROM huesped_tour ht
      JOIN tour t ON t.id_tour = ht.id_tour
     WHERE ht.id_huesped = p_id_huesped;

    g_tours_usd := NVL(v_total,0);
    RETURN NVL(v_total,0);

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      g_tours_usd := 0;
      RETURN 0;
    WHEN OTHERS THEN
      g_tours_usd := 0;
      RETURN 0;
  END;
END pkg_cobranza_hotel;
/
SHOW ERRORS;


/* ------------------------------------------------------------
   PROCEDIMIENTO: SP_COBRANZA_DIARIA
   - Recibe fecha de proceso y tipo de cambio
   - Calcula montos y carga DETALLE_DIARIO_HUESPEDES
   ------------------------------------------------------------ */
CREATE OR REPLACE PROCEDURE sp_cobranza_diaria(
  p_fecha_proceso IN DATE,
  p_tipo_cambio   IN NUMBER
)
IS
  CURSOR c_huespedes IS
    SELECT h.id_huesped,
           h.nom_huesped || ' ' || h.appat_huesped || ' ' || h.apmat_huesped AS nombre,
           r.id_reserva,
           r.ingreso,
           r.estadia
      FROM huesped h
      JOIN reserva r ON r.id_huesped = h.id_huesped
     WHERE (r.ingreso + r.estadia) = p_fecha_proceso;

  v_agencia           VARCHAR2(40);
  v_aloj_usd          NUMBER;
  v_consumos_usd      NUMBER;
  v_tours_usd         NUMBER;
  v_persona_usd       NUMBER;
  v_subtotal_usd      NUMBER;
  v_desc_cons_usd     NUMBER;
  v_desc_agencia_usd  NUMBER;
  v_total_usd         NUMBER;

  v_aloj_clp          NUMBER;
  v_consumos_clp      NUMBER;
  v_tours_clp         NUMBER;
  v_subtotal_clp      NUMBER;
  v_desc_cons_clp     NUMBER;
  v_desc_agencia_clp  NUMBER;
  v_total_clp         NUMBER;
BEGIN
  DELETE FROM detalle_diario_huespedes;
  DELETE FROM reg_errores;
  COMMIT;

  v_persona_usd := ROUND(35000 / p_tipo_cambio);

  FOR x IN c_huespedes LOOP
    v_agencia := fn_agencia_huesped(x.id_huesped);

    SELECT NVL(SUM(hb.valor_habitacion + hb.valor_minibar),0) * x.estadia
      INTO v_aloj_usd
      FROM detalle_reserva dr
      JOIN habitacion hb ON hb.id_habitacion = dr.id_habitacion
     WHERE dr.id_reserva = x.id_reserva;

    v_consumos_usd := fn_consumos_huesped(x.id_huesped);
    v_tours_usd    := pkg_cobranza_hotel.fn_tours_huesped(x.id_huesped);

    v_subtotal_usd := ROUND(
      NVL(v_aloj_usd,0) + NVL(v_consumos_usd,0) + NVL(v_persona_usd,0)
    );

    v_desc_cons_usd := fn_desc_consumos(v_consumos_usd);

    IF UPPER(v_agencia) = 'VIAJES ALBERTI' THEN
      v_desc_agencia_usd := ROUND(v_subtotal_usd * 0.12);
    ELSE
      v_desc_agencia_usd := 0;
    END IF;

    v_total_usd := ROUND(v_subtotal_usd - v_desc_cons_usd - v_desc_agencia_usd);

    v_aloj_clp         := ROUND(v_aloj_usd * p_tipo_cambio);
    v_consumos_clp     := ROUND(v_consumos_usd * p_tipo_cambio);
    v_tours_clp        := ROUND(v_tours_usd * p_tipo_cambio);
    v_subtotal_clp     := ROUND(v_subtotal_usd * p_tipo_cambio);
    v_desc_cons_clp    := ROUND(v_desc_cons_usd * p_tipo_cambio);
    v_desc_agencia_clp := ROUND(v_desc_agencia_usd * p_tipo_cambio);
    v_total_clp        := ROUND(v_total_usd * p_tipo_cambio);

    INSERT INTO detalle_diario_huespedes(
      id_huesped, nombre, agencia,
      alojamiento, consumos, tours,
      subtotal_pago, descuento_consumos, descuentos_agencia, total
    )
    VALUES (
      x.id_huesped, x.nombre, v_agencia,
      v_aloj_clp, v_consumos_clp, v_tours_clp,
      v_subtotal_clp, v_desc_cons_clp, v_desc_agencia_clp, v_total_clp
    );
  END LOOP;

  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_cobranza_diaria;
/
SHOW ERRORS;


/* ============================================================
   EJECUCIÓN DEL PROCESO (según enunciado)
   Fecha proceso: 18/08/2021
   Tipo cambio  : 915
   ============================================================ */
BEGIN
  sp_cobranza_diaria(TO_DATE('18/08/2021','DD/MM/YYYY'), 915);
END;
/