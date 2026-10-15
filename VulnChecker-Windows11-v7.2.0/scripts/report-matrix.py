"""Portable streaming XLSX export for the application's infrastructure result table.

Uses OOXML and the Python standard library so customer PCs need no Excel/Node dependency.
All values are immutable observations from one SQLite read snapshot; no active formulas.
"""
from pathlib import Path
from xml.sax.saxutils import escape
import zipfile
import math
import unicodedata
import json
from functools import lru_cache

LABELS={'GOOD':'양호','VULNERABLE':'취약','MANUAL':'수동 확인','N/A':'해당 없음'}
NS='http://schemas.openxmlformats.org/spreadsheetml/2006/main'

@lru_cache(maxsize=64)
def profile_label(identifier):
    path=Path(__file__).resolve().parents[1]/'infrastructure/profiles.json'
    if not path.exists():return identifier
    return next((p['Label'] for p in json.loads(path.read_text(encoding='utf-8-sig')) if p['Id']==identifier),identifier)

def column(index):
    out=''
    while index: index,r=divmod(index-1,26);out=chr(65+r)+out
    return out

def cell(value, ref, style=0):
    if isinstance(value,(int,float)):
        return f'<c r="{ref}" s="{style}"><v>{value}</v></c>'
    value=''.join(c for c in str(value) if ord(c)>=32 or c in '\n\t')[:32767]
    return f'<c r="{ref}" s="{style}" t="inlineStr"><is><t xml:space="preserve">{escape(value)}</t></is></c>'

def write_sheet(z, name, headers, rows, widths, freeze=1, result_start=None):
    with z.open(name,'w') as stream:
        def write(s):stream.write(s.encode('utf-8'))
        write(f'<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="{NS}"><sheetViews><sheetView workbookViewId="0" showGridLines="0"><pane xSplit="{freeze}" ySplit="1" topLeftCell="{column(freeze+1)}2" activePane="bottomRight" state="frozen"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight="22"/><cols>')
        for i,w in enumerate(widths,1):write(f'<col min="{i}" max="{i}" width="{w}" customWidth="1"/>')
        write('</cols><sheetData><row r="1" ht="38" customHeight="1">')
        for i,value in enumerate(headers,1):write(cell(value,column(i)+'1',1))
        write('</row>');last=1
        styles={'양호':3,'취약':4,'수동 확인':5,'해당 없음':6,'결과 없음':7}
        for last,row in enumerate(rows,2):
            row=list(row)
            line_count=1
            for value,width in zip(row,widths):
                if isinstance(value,str):
                    wrapped=sum(max(1,math.ceil(sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in line)/max(1,width-2))) for line in value.split('\n'))
                    line_count=max(line_count,wrapped)
            write(f'<row r="{last}" ht="{min(409,max(22,line_count*16+6))}" customHeight="1">')
            for i,value in enumerate(row,1):
                style=styles.get(value,2) if isinstance(value,str) and result_start and i>=result_start else (8 if isinstance(value,(int,float)) else 2)
                write(cell(value,column(i)+str(last),style))
            write('</row>')
        write(f'</sheetData><autoFilter ref="A1:{column(len(headers))}{last}"/><pageMargins left="0.3" right="0.3" top="0.5" bottom="0.5" header="0.2" footer="0.2"/><pageSetup orientation="landscape"/></worksheet>')

def asset_rows(db, source):
    return db.execute('''SELECT a.name,a.platform,a.failed,a.detailed,a.server_name,a.instance_id,
      COALESCE(SUM(r.count),0) AS total,
      COALESCE(SUM(CASE WHEN r.status='GOOD' THEN r.count ELSE 0 END),0) AS good,
      COALESCE(SUM(CASE WHEN r.status='VULNERABLE' THEN r.count ELSE 0 END),0) AS vulnerable,
      COALESCE(SUM(CASE WHEN r.status='MANUAL' THEN r.count ELSE 0 END),0) AS manual,
      COALESCE(SUM(CASE WHEN r.status='N/A' THEN r.count ELSE 0 END),0) AS na
      FROM assets a LEFT JOIN result_counts r ON a.source_id=r.source_id AND a.name=r.asset
      WHERE a.source_id=? GROUP BY a.name ORDER BY a.name''',(source,))

def item_rows(db, source):
    return db.execute('''SELECT a.platform,c.item_id,MIN(c.title) AS title,COUNT(*) AS total,
      SUM(c.status='GOOD') AS good,SUM(c.status='VULNERABLE') AS vulnerable,
      SUM(c.status='MANUAL') AS manual,SUM(c.status='N/A') AS na
      FROM checks c JOIN assets a ON a.source_id=c.source_id AND a.name=c.asset
      WHERE c.source_id=? GROUP BY a.platform,c.item_id ORDER BY a.platform,c.item_id''',(source,))

def export(db, source, path, customer, stats, source_name=None):
    items=[(r['platform'],r['item_id']) for r in item_rows(db,source)]
    if len(items)>16379:raise ValueError('Excel 열 제한을 초과했습니다. 점검 실행을 나누어 추출하세요.')
    if stats['assets']>1048575:raise ValueError('Excel 행 제한을 초과했습니다. 점검 실행을 나누어 추출하세요.')
    def matrix_rows():
        checks=iter(db.execute('SELECT asset,item_id,status FROM checks WHERE source_id=? ORDER BY asset,item_id',(source,)))
        current=next(checks,None)
        for a in asset_rows(db,source):
            values={}
            while current and current['asset']==a['name']:
                values[current['item_id']]=LABELS[current['status']];current=next(checks,None)
            label=a['server_name']+' / '+a['instance_id'] if a['instance_id'] and a['instance_id']!='os' else a['name']
            yield [label,profile_label(a['platform']),'실패' if a['failed'] else '완료','확인' if a['detailed'] else '미완전']+[values.get(i,'결과 없음') if p==a['platform'] else '범위 외' for p,i in items]
    with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as z:
        names=['전체 판정 통계','서버별 항목 결과','점검 항목별 통계']
        content='<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        for n in range(1,4):content+=f'<Override PartName="/xl/worksheets/sheet{n}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        z.writestr('[Content_Types].xml',content+'</Types>')
        z.writestr('_rels/.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        z.writestr('xl/workbook.xml',f'<workbook xmlns="{NS}" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets>'+''.join(f'<sheet name="{name}" sheetId="{n}" r:id="rId{n}"/>' for n,name in enumerate(names,1))+'</sheets></workbook>')
        relationships='<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+''.join(f'<Relationship Id="rId{n}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{n}.xml"/>' for n in range(1,4))+'<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
        z.writestr('xl/_rels/workbook.xml.rels',relationships)
        colors=['24374B','FFFFFF','E7F0EB','FBE7E5','FFF2CF','EEF0F3','F5F5F5']
        fills='<fills count="9"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'+''.join(f'<fill><patternFill patternType="solid"><fgColor rgb="FF{c}"/><bgColor indexed="64"/></patternFill></fill>' for c in colors)+'</fills>'
        border='<borders count="1"><border>'+''.join(f'<{edge} style="thin"><color rgb="FFD9D9D9"/></{edge}>' for edge in ('left','right','top','bottom'))+'<diagonal/></border></borders>'
        xf='<cellXfs count="9"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        for fillid,fontid,align in [(2,1,'center'),(3,0,'left'),(4,0,'center'),(5,0,'center'),(6,0,'center'),(7,0,'center'),(8,0,'center'),(3,0,'right')]:xf+=f'<xf numFmtId="0" fontId="{fontid}" fillId="{fillid}" borderId="0" xfId="0" applyAlignment="1" applyFill="1"><alignment horizontal="{align}" vertical="center" wrapText="1"/></xf>'
        z.writestr('xl/styles.xml',f'<styleSheet xmlns="{NS}"><fonts count="2"><font><sz val="11"/><name val="맑은 고딕"/><color rgb="FF000000"/></font><font><b/><sz val="11"/><name val="맑은 고딕"/><color rgb="FFFFFFFF"/></font></fonts>'+fills+border+'<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'+xf+'</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>')
        summary=[['고객사',customer],['결과 출처',source_name or source],['물리 서버',stats['physical_assets']],['OS / 서비스 점검 대상',stats['assets']],['수행 실패 자산',stats['failed_assets']],['항목 결과 합계',stats['total_checks']]]
        summary.extend([[LABELS[k],stats['counts'].get(k,0)] for k in LABELS])
        summary.extend([['양호율',str(stats['good_rate'])+'%' if stats['good_rate'] is not None else '산출 불가'],['집계 기준','SQLite 결과 스냅샷. 통계는 판정 합계, 항목별 표와 행렬은 수집된 상세 결과입니다.'],['결과 없음','상세 판정 미수집 또는 해당 서버의 점검 범위 밖. 해당 없음 판정으로 계산하지 않습니다.']])
        write_sheet(z,'xl/worksheets/sheet1.xml',['전체 점검 현황','값'],summary,[28,85])
        write_sheet(z,'xl/worksheets/sheet2.xml',['서버 / 인스턴스','점검 종류','수행 상태','증적']+[profile_label(p)+' '+i for p,i in items],matrix_rows(),[30,24,12,12]+[20]*len(items),4,5)
        write_sheet(z,'xl/worksheets/sheet3.xml',['점검 종류','항목 ID','점검 항목','결과 합계','양호','취약','수동 확인','해당 없음'],([profile_label(r['platform'])]+[r[k] for k in ('item_id','title','total','good','vulnerable','manual','na')] for r in item_rows(db,source)),[24,16,64,14,14,14,14,14])
    return str(Path(path))
