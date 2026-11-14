import { indianStates } from './catalog';

export const stateCodes = indianStates.map((name, index) => ({ name, code: String(index + 1).padStart(2, '0') }));

/** Two-digit form codes used in every acknowledgement number; each form has its own serial counter in the database. */
export const formCodes = {
  scholarship: '01',
  youngInnovators: '02',
  fundingProgramme: '03',
  foundation: '04',
  registration: '05',
  enquiry: '06',
} as const;

/** YYMMDD + 2-digit state (00 when the form has no state) + 2-digit form + 5-digit serial. */
export function formatAcknowledgement(dateYYMMDD: string, stateCode: string, formCode: string, serial: number) {
  if (!/^\d{6}$/.test(dateYYMMDD) || !/^(0\d|[12]\d|3[0-6])$/.test(stateCode) || !/^(0[1-9]|[1-9]\d)$/.test(formCode) || !Number.isInteger(serial) || serial < 1 || serial > 99999) throw new Error('Invalid acknowledgement values');
  return dateYYMMDD + stateCode + formCode + String(serial).padStart(5, '0');
}
/** Temporary Registration ID given at step 1 of the scholarship form, before the payment ID is shared. */
export const isTemporaryRegistrationId = (value: string) => /^R\d{15}$/.test(value);
export function canApprove(paymentStatus: string) { return paymentStatus === 'paid'; }
